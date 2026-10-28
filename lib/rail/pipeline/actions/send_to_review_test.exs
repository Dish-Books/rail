defmodule Rail.Pipeline.Actions.SendToReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
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
    # A branch review can read is a branch the remote has, so the worktree here is
    # one that has actually been pushed.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])

    worktree_path = create_temp_git_repo()
    git!(worktree_path, ["remote", "add", "origin", remote])
    git!(worktree_path, ["push", "--set-upstream", "origin", "main"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

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

  test "hands the task to review and latches the engineer run", %{task: task, run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_review(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  # Each that drives the app has a browser of its own, so none waits on another.
  test "starts QA, the code reviewer and the demo recorder together", %{task: task, run: run} do
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter.", record_demo: true})
    test_pid = self()

    stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_to_review(run)

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

    assert {:ok, %Run{}} = Pipeline.send_to_review(run)

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

    assert {:ok, %Run{}} = Pipeline.send_to_review(run)

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

      base = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
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

      commit = fn files ->
        for {path, body} <- files do
          File.mkdir_p!(Path.dirname(Path.join(repo, path)))
          File.write!(Path.join(repo, path), body)
        end

        git!(repo, ["add", "."])
        git!(repo, ["commit", "-m", "round 2"])
        git!(repo, ["push", "origin", "main"])
      end

      %{qa_run: qa_run, commit: commit}
    end

    # Nothing a person sees moved, so walking the app again only spends QA's minutes.
    test "that changed only tests and docs starts the code reviewer alone, and QA's report says why", %{
      task: task,
      run: run,
      qa_run: qa_run,
      commit: commit
    } do
      commit.([{"test/bill_test.exs", "test\n"}, {"README.md", "docs\n"}])

      assert {:ok, %Run{}} = Pipeline.send_to_review(run)

      assert_received {:started, :review}
      refute_received {:started, _stage}

      line = "Round 2 changed only files nobody sees in the app (README.md, test/bill_test.exs), so QA did not run."
      assert [qa: ^line] = Pipeline.read_reports(task)
      assert %Run{stage_outcome: :skipped} = Repo.reload!(qa_run)
      assert ["[qa] " <> ^line] = qa_run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    test "that changed a file the app runs starts QA and the demo too", %{run: run, commit: commit} do
      commit.([{"test/bill_test.exs", "test\n"}, {"lib/bill.ex", "code\n"}])

      assert {:ok, %Run{}} = Pipeline.send_to_review(run)

      for stage <- [:qa, :review, :demo], do: assert_received({:started, ^stage})
    end

    test "of a project that names no unseen files starts QA", %{project: project, run: run, commit: commit} do
      {:ok, _project} = Projects.update_project(system_scope(), project, %{qa_skip_paths: []})
      commit.([{"test/bill_test.exs", "test\n"}])

      assert {:ok, %Run{}} = Pipeline.send_to_review(run)

      assert_received {:started, :qa}
    end
  end

  # The first round checks every acceptance criterion, whatever it changed.
  test "round 1 starts QA though it changed only tests", %{task: task, run: run, worktree_path: repo} do
    Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Test it.", approved_at: DateTime.utc_now()})
    File.write!(Path.join(repo, "bill_test.exs"), "test\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "round 1"])
    git!(repo, ["push", "origin", "main"])
    test_pid = self()

    stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Run{}} = Pipeline.send_to_review(run)

    assert_received {:started, :qa}
  end

  # The engineer commits its own work, so what it left uncommitted stays behind rather than holding Review up.
  test "sends the pushed work on with work left uncommitted beside it", %{task: task, run: run, worktree_path: repo} do
    File.write!(Path.join(repo, "uncommitted.ex"), "one\n")
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{}} = Pipeline.send_to_review(run)
    assert %Task{stage: :review} = Repo.reload!(task)
    assert File.exists?(Path.join(repo, "uncommitted.ex"))
  end

  # A commit nobody else can see is not a change anyone can review.
  test "refuses commits the remote has never been told about", %{task: task, run: run, worktree_path: repo} do
    File.write!(Path.join(repo, "local.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "never pushed"])

    assert {:error, :unpushed_changes} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses while something is still running on the task", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses a task that has not reached engineer", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :plan})

    assert {:error, {:invalid_stage, :plan}} = Pipeline.send_to_review(run)
  end

  # The fixes Review asks for are made inside Review, so nothing sends a task there twice.
  test "refuses a task already past engineer", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
    reject(Tools, :start_os_process, 2)

    assert {:error, {:invalid_stage, :review}} = Pipeline.send_to_review(run)
  end

  test "a project with CI sends nothing to review that CI has not passed", %{project: project, task: task, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})

    assert {:error, :ci_not_passed} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a pass for an earlier commit is not a pass for this one", %{
    project: project,
    run: run,
    worktree_path: worktree_path
  } do
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

    assert {:error, :ci_not_passed} = Pipeline.send_to_review(run)

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: run.task_id,
      kind: :ci,
      head_sha: String.trim(git!(worktree_path, ["rev-parse", "HEAD"])),
      exit_code: 0,
      stream_path: "/tmp/#{run.id}-again.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_review(run)
  end
end
