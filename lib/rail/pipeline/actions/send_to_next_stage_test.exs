defmodule Rail.Pipeline.Actions.SendToNextStageTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_str_1", "identifier" => "STR-1", "title" => "Send To Review"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send To Review"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # Git is only ever asked through Rail.Git, so the worktree is a plain directory. A branch review can read is a
    # branch the remote has, so it answers as one that has been pushed, up to date with main, on one commit.
    worktree_path = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree_path)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})

    stub(Git, :branch_unpushed?, fn ^worktree_path -> false end)
    stub(Git, :base_status, fn ^worktree_path, "main" -> %{behind: false, conflicts: []} end)

    stub(Git, :branch_fingerprint, fn ^worktree_path ->
      %{head_sha: String.duplicate("a", 40), dirty_digest: String.duplicate("0", 64)}
    end)

    stub(Git, :commits_since, fn ^worktree_path, _sha -> {:ok, %{merges: false}} end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_to_review",
        started_at: DateTime.utc_now()
      })

    %{
      backend: backend,
      project: project,
      task: task,
      run: Repo.preload(run, [:task, :role]),
      worktree_path: worktree_path
    }
  end

  # The engineer commits its own work, so what it left uncommitted stays behind rather than holding Review up.
  test "hands the task to review and latches the engineer run, with work left uncommitted beside it", %{
    task: task,
    run: run,
    worktree_path: repo
  } do
    File.write!(Path.join(repo, "uncommitted.ex"), "one\n")

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_next_stage(run)
    assert %Task{stage: :review} = Repo.reload!(task)
    assert File.exists?(Path.join(repo, "uncommitted.ex"))
  end

  test "hands the task to the custom stage its sequence places after Engineer, then past it once it is approved", %{
    project: project,
    task: task,
    run: run
  } do
    stages = [
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    Repo.preload(task, :issue).issue
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:stages, stages)
    |> Repo.update!()

    test_pid = self()

    stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_next_stage(run)
    assert %Task{stage: :custom, custom_stage: "License check"} = Repo.reload!(task)
    assert_received {:started, %Role{custom_stage: "License check"}}

    # Approved, the custom stage runs once per task, so a later round's work goes to Review.
    {:ok, license} = Roles.get_custom_stage_role(project.id, "License check")

    Repo.update_all(from(r in Run, where: r.task_id == ^task.id and r.role_id == ^license.id),
      set: [stage_outcome: :done, status: :finished]
    )

    {:ok, _back} = Pipeline.update_task(Repo.reload!(task), %{stage: :engineer})
    {:ok, _reopened} = run |> Run.changeset(%{stage_outcome: :in_progress}) |> Repo.update()

    assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)
    assert %Task{stage: :review} = Repo.reload!(task)
    assert_received {:started, %Role{stage: :qa}}
  end

  # Each that drives the app has a browser of its own, so none waits on another.
  test "starts QA, the code reviewer and the demo recorder together", %{task: task, run: run} do
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter.", record_demo: true})
    test_pid = self()

    stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)

    for stage <- [:qa, :review, :demo], do: assert_received({:started, ^stage})
    refute_received {:started, _stage}
  end

  test "starts QA and the code reviewer and no demo for a task whose workflow turned the demo off", %{
    task: task,
    run: run
  } do
    Repo.preload(task, :issue).issue |> Ecto.Changeset.change(skipped_steps: [:demo]) |> Repo.update!()
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter.", record_demo: true})
    test_pid = self()

    stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)

    for stage <- [:qa, :review], do: assert_received({:started, ^stage})
    refute_received {:started, _stage}
  end

  test "starts only QA and the code reviewer when the round's plan asks for no demo", %{
    task: task,
    run: run
  } do
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter."})
    test_pid = self()

    stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)

    for stage <- [:qa, :review], do: assert_received({:started, ^stage})
    refute_received {:started, _stage}
  end

  describe "a later round" do
    setup %{project: project, task: task, worktree_path: repo} do
      {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)

      {:ok, qa_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: qa.id,
          status: :finished,
          stage_outcome: :done,
          started_at: DateTime.utc_now()
        })

      base = String.duplicate("b", 40)
      Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter.", approved_at: DateTime.utc_now()})

      Repo.insert!(%Round{
        task_id: task.id,
        number: 2,
        plan: "Test the nil.",
        base_head: base,
        approved_at: DateTime.utc_now(),
        record_demo: true
      })

      test_pid = self()

      stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
        send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
        {:ok, %OsProcess{run: spawned}}
      end)

      # The round started at `base` and merged nothing in since, so the files it changed are asked of git from there.
      changed = fn paths ->
        expect(Git, :list_round_paths, fn %Task{worktree_path: ^repo}, %{number: 2, base: ^base, merged: false} ->
          {:ok, paths}
        end)
      end

      %{qa_run: qa_run, changed: changed}
    end

    # Nothing a person sees moved, so walking the app again only spends QA's minutes.
    test "that changed only tests and docs starts the code reviewer alone, and QA's report says why", %{
      task: task,
      run: run,
      qa_run: qa_run,
      changed: changed
    } do
      changed.(["README.md", "test/bill_test.exs"])

      assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)

      assert_received {:started, :review}
      refute_received {:started, _stage}

      line = "Round 2 changed only files nobody sees in the app (README.md, test/bill_test.exs), so QA did not run."
      assert [qa: ^line] = Pipeline.read_reports(task)
      assert %Run{stage_outcome: :skipped} = Repo.reload!(qa_run)
      assert ["[qa] " <> ^line] = qa_run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    test "that changed a file the app runs starts QA and the demo too", %{run: run, changed: changed} do
      changed.(["lib/bill.ex", "test/bill_test.exs"])

      assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)

      for stage <- [:qa, :review, :demo], do: assert_received({:started, ^stage})
    end

    # With nothing to match them against, the round's files are never asked for.
    test "of a project that names no unseen files starts QA", %{project: project, run: run} do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{qa_skip_paths: []})
      reject(Git, :list_round_paths, 2)

      assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)

      assert_received {:started, :qa}
    end
  end

  # The first round checks every acceptance criterion, whatever it changed.
  test "round 1 starts QA without asking what it changed", %{task: task, run: run} do
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Test it.", approved_at: DateTime.utc_now()})
    reject(Git, :list_round_paths, 2)
    test_pid = self()

    stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_to_next_stage(run)

    assert_received {:started, :qa}
  end

  # A commit nobody else can see is not a change anyone can review.
  test "refuses commits the remote has never been told about", %{task: task, run: run, worktree_path: repo} do
    expect(Git, :branch_unpushed?, fn ^repo -> true end)

    assert {:error, :unpushed_changes} = Pipeline.send_to_next_stage(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses while something is still running on the task", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_to_next_stage(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses a task that has not reached engineer", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :plan})

    assert {:error, {:invalid_stage, :plan}} = Pipeline.send_to_next_stage(run)
  end

  # The fixes Review asks for are made inside Review, so nothing sends a task there twice.
  test "refuses a task already past engineer", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
    reject(Tools, :start_os_process, 2)

    assert {:error, {:invalid_stage, :review}} = Pipeline.send_to_next_stage(run)
  end

  test "a project with CI sends nothing to review that CI has not passed", %{project: project, task: task, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    assert {:error, :ci_not_passed} = Pipeline.send_to_next_stage(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # The setup has the worktree on the commit whose sha is all a's.
  test "a pass for an earlier commit is not a pass for this one", %{project: project, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :ci,
      head_sha: "0000000000000000000000000000000000000000",
      exit_code: 0,
      stream_path: "/tmp/#{run.id}.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:error, :ci_not_passed} = Pipeline.send_to_next_stage(run)

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :ci,
      head_sha: String.duplicate("a", 40),
      exit_code: 0,
      stream_path: "/tmp/#{run.id}-again.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_next_stage(run)
  end
end
