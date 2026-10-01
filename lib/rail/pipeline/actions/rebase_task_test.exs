defmodule Rail.Pipeline.Actions.RebaseTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Rebase Project",
        github_repo: "org/rebase",
        github_installation_id: 47_071,
        linear_team_key: "RBS",
        default_branch: "main",
        clone_path: "/tmp/repos/rebase"
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-opus-5-5",
        system_prompt: "You are the engineer."
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_rbs",
        identifier: "RBS-1",
        title: "Rebase",
        state: :backlog
      })
      |> Repo.insert!()

    worktree_path = create_temp_git_repo()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :review,
          worktree_name: "rbs-1",
          worktree_path: worktree_path,
          scratch_path: Path.join(System.tmp_dir!(), "rebase_#{System.unique_integer([:positive])}")
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_rebase",
        ci_failure_streak: 2,
        started_at: DateTime.utc_now()
      })

    %{project: project, task: task, run: run, worktree_path: worktree_path}
  end

  test "a rebase that goes cleanly is pushed without the engineer", %{task: task, run: run} do
    expect(Git, :fetch_default_branch, fn %Project{default_branch: "main"}, _path -> :ok end)
    expect(Git, :rebase_branch, fn _scope, %Task{} -> :ok end)
    expect(Git, :push_branch, fn _scope, _task -> :ok end)
    reject(Tools, :start_os_process, 2)

    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:ok, %Task{is_rebasing: false}} = Pipeline.rebase_task(system_scope(), task)
    assert %Run{status: :finished, stage_outcome: :done, ci_failure_streak: 0} = Repo.reload!(run)
    assert "[rail] Rebased onto origin/main." in Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  # Nothing to replay leaves HEAD where it was, so there is no new code to review.
  test "a rebase that finds the branch up to date leaves the task where it was", %{task: task} do
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    expect(Git, :rebase_branch, fn _scope, _task -> :ok end)
    stub(Git, :push_branch, fn _scope, _task -> :ok end)

    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:ok, %Task{stage: :review}} = Pipeline.rebase_task(system_scope(), task)
  end

  test "a rebase that rewrites the branch of a task at QA sends it back to engineer", %{
    task: task,
    run: run,
    worktree_path: worktree_path
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa})
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)

    expect(Git, :rebase_branch, fn _scope, %Task{} ->
      git!(worktree_path, ["commit", "--allow-empty", "-m", "replayed onto main"])
      :ok
    end)

    stub(Git, :push_branch, fn _scope, _task -> :ok end)

    Req.Test.stub(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:ok, %Task{stage: :engineer, is_rebasing: false}} = Pipeline.rebase_task(system_scope(), task)
    assert %Run{status: :finished, stage_outcome: :done} = Repo.reload!(run)
  end

  test "a rebase that stops on conflicts goes to the engineer to resolve", %{task: task, run: run} do
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    expect(Git, :rebase_branch, fn _scope, _task -> {:conflicts, ["lib/app.ex", "mix.lock"]} end)

    expect(Tools, :start_os_process, fn spawned, ["-p", prompt | _rest] ->
      assert prompt =~ "Rail rebased this branch onto origin/main, and it stopped on conflicts in:"
      assert prompt =~ "- lib/app.ex\n- mix.lock"
      assert prompt =~ "no `git rebase --continue`"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Task{stage: :engineer, is_rebasing: true}} = Pipeline.rebase_task(system_scope(), task)
    assert %Run{status: :running} = Repo.reload!(run)

    assert [
             "[rail] Rebase onto origin/main stopped on conflicts in lib/app.ex, mix.lock. Asked the engineer to resolve them."
           ] = Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "the engineer resolving conflicts runs on the prompt merged to the project's .rail/prompts", %{
    project: project,
    task: task
  } do
    remote = create_temp_git_repo(prefix: "rail_rebase_prompt_remote")
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "From the repo.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])
    clone = create_temp_git_repo(prefix: "rail_rebase_prompt_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])
    project |> Project.changeset(%{clone_path: clone}) |> Repo.update!()

    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    expect(Git, :rebase_branch, fn _scope, _task -> {:conflicts, ["lib/app.ex"]} end)

    expect(Tools, :start_os_process, fn spawned, argv ->
      assert ["--append-system-prompt", "From the repo."] in Enum.chunk_every(argv, 2, 1)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %Task{is_rebasing: true}} = Pipeline.rebase_task(system_scope(), task)
  end

  test "a rebase git refuses says why", %{task: task, run: run} do
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    expect(Git, :rebase_branch, fn _scope, _task -> {:error, "fatal: invalid upstream 'origin/main'"} end)

    assert {:error, "fatal: invalid upstream 'origin/main'"} = Pipeline.rebase_task(system_scope(), task)
    assert ["[rail] Rebase onto origin/main failed."] = Enum.map(Pipeline.list_run_events(run), & &1.line)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a fetch that fails rebases nothing", %{task: task} do
    expect(Git, :fetch_default_branch, fn _project, _path -> {:error, "could not read from remote"} end)
    reject(&Git.rebase_branch/2)

    assert {:error, "could not read from remote"} = Pipeline.rebase_task(system_scope(), task)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "an engineer that cannot be resumed on the conflicts says why", %{task: task} do
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    stub(Git, :rebase_branch, fn _scope, _task -> {:conflicts, ["lib/app.ex"]} end)

    expect(Tools, :start_os_process, fn spawned, _argv ->
      {:error, {:spawn_failed, :enoent, %{spawned | error: "Failed to spawn runner: :enoent"}}}
    end)

    assert {:error, "Failed to spawn runner: :enoent"} = Pipeline.rebase_task(system_scope(), task)
  end

  test "with dispatch off, the conflicts wait", %{task: task} do
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    stub(Git, :rebase_branch, fn _scope, _task -> {:conflicts, ["lib/app.ex"]} end)
    expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert {:error, :dispatch_disabled} = Pipeline.rebase_task(system_scope(), task)
  end

  test "a rebase stopped on conflicts can be asked for again, dirty as it is", %{task: task, worktree_path: worktree_path} do
    File.write!(Path.join(worktree_path, "conflicted.ex"), "<<<<<<<\n")
    stub(Git, :rebase_in_progress?, fn _path -> true end)
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    expect(Git, :rebase_branch, fn _scope, _task -> {:error, "could not continue"} end)

    assert {:error, "could not continue"} = Pipeline.rebase_task(system_scope(), task)
  end

  test "refuses a task something is working on, or that has nothing to rebase", %{
    task: task,
    run: run,
    worktree_path: worktree_path
  } do
    reject(Git, :fetch_default_branch, 2)

    File.write!(Path.join(worktree_path, "loose.ex"), "one\n")
    assert {:error, :uncommitted_changes} = Pipeline.rebase_task(system_scope(), task)
    assert %Task{stage: :review} = Repo.reload!(task)
    File.rm!(Path.join(worktree_path, "loose.ex"))

    {:ok, running} = Pipeline.update_run(run, %{status: :running})
    assert {:error, :task_busy} = Pipeline.rebase_task(system_scope(), task)
    assert %Task{stage: :review} = Repo.reload!(task)
    {:ok, _idle} = Pipeline.update_run(running, %{status: :finished})

    {:ok, gone} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})
    assert {:error, :no_worktree} = Pipeline.rebase_task(system_scope(), gone)
    assert %Task{stage: :review} = Repo.reload!(gone)

    {:ok, cleaned} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})
    assert {:error, :cleaned_up} = Pipeline.rebase_task(system_scope(), cleaned)

    Repo.delete!(run)
    {:ok, restored} = Pipeline.update_task(cleaned, %{cleaned_up_at: nil, worktree_path: worktree_path})
    assert {:error, :no_engineer_run} = Pipeline.rebase_task(system_scope(), restored)
  end
end
