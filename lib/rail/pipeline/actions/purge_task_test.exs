defmodule Rail.Pipeline.Actions.PurgeTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools.Schemas.BrowserSession
  alias Rail.Tools.Schemas.OsProcess

  # Git is faked at its boundary: removing a worktree or a branch for real is for `Rail.Git`'s own tests.
  setup do
    stub(Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    stub(Git, :remove_worktree, fn _repo_path, _worktree_path -> :ok end)
    stub(Git, :delete_branch, fn _repo_path, _branch -> :ok end)
    :ok
  end

  test "stops only the runs still going and stamps nothing on the task", %{project: project} do
    {:ok, %Task{id: task_id} = task} =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_purge_runs",
        identifier: "PRG-1",
        title: "Purged",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Repo.preload(:project)
      |> Pipeline.create_task(:engineer)

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, %Run{id: running_id}} =
      Pipeline.create_run(%{task_id: task_id, role_id: engineer.id, status: :running, started_at: DateTime.utc_now()})

    {:ok, %Run{id: failed_id}} =
      Pipeline.create_run(%{task_id: task_id, role_id: engineer.id, status: :failed, started_at: DateTime.utc_now()})

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{running_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{failed_id}")

    assert :ok = Pipeline.purge_task(task)

    assert_receive {:run_changed, ^running_id}
    refute_receive {:run_changed, ^failed_id}, 50
    assert %Task{id: ^task_id, cleaned_up_at: nil} = Repo.get(Task, task_id)
  end

  # The task's delete takes the session rows with it, and the reconciler only closes contexts it has a row for.
  test "closes the task's open browser sessions", %{project: project} do
    {:ok, %Task{id: task_id} = task} =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_purge_browser",
        identifier: "PRG-3",
        title: "Purged browser",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Repo.preload(:project)
      |> Pipeline.create_task(:review)

    %BrowserSession{id: session_id} =
      Repo.insert!(%BrowserSession{task_id: task_id, name: "qa", status: :running, started_at: DateTime.utc_now()})

    Phoenix.PubSub.subscribe(Rail.PubSub, "browser:#{task_id}:qa")

    assert :ok = Pipeline.purge_task(task)

    assert %BrowserSession{status: :finished, ended_reason: :closed} = Repo.get!(BrowserSession, session_id)
    assert_receive {:browser_closed, ^task_id, "qa"}
  end

  # Runs have no foreign key to tasks, so nothing else would take them.
  test "deletes the task's runs with their processes and events", %{project: project} do
    [{:ok, %Task{id: task_id} = task}, {:ok, %Task{id: other_task_id}}] =
      for external_id <- ["lin_purge_rows", "lin_purge_neighbor"] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: external_id,
          identifier: external_id,
          title: external_id,
          state: :in_progress
        })
        |> Repo.insert!()
        |> Repo.preload(:project)
        |> Pipeline.create_task(:engineer)
      end

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    now = DateTime.utc_now()

    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{task_id: task_id, role_id: engineer.id, status: :running, started_at: now})

    {:ok, %Run{id: other_run_id}} =
      Pipeline.create_run(%{task_id: other_task_id, role_id: engineer.id, status: :running, started_at: now})

    %OsProcess{id: os_process_id} =
      Repo.insert!(%OsProcess{
        run_id: run_id,
        task_id: task_id,
        stream_path: "/dev/null",
        status: :running,
        started_at: now,
        reserved_cpus: 1,
        launch: Jason.encode!(%{"executable" => "/bin/true", "args" => [], "env" => %{}, "cwd" => "/tmp"})
      })

    Pipeline.append_run_events(run_id, nil, ["working on it"])

    assert :ok = Pipeline.purge_task(task)

    assert Repo.get(Run, run_id) == nil
    assert Repo.get(OsProcess, os_process_id) == nil
    assert [] = Repo.all(from(e in RunEvent, where: e.run_id == ^run_id))
    assert %Run{id: ^other_run_id} = Repo.get(Run, other_run_id)
  end

  test "removes the task's worktree, branch and scratch folder", %{project: %{clone_path: clone_path} = project} do
    worktree_path = Path.join(System.tmp_dir!(), "rail_purge_wt_#{System.unique_integer([:positive])}")
    scratch_dir = Path.join(System.tmp_dir!(), "rail_purge_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    File.write!(Path.join(scratch_dir, "notes.md"), "temporary content")

    {:ok, task} =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_purge_files",
        identifier: "PRG-2",
        title: "Purged with its files",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Repo.preload(:project)
      |> Pipeline.create_task(:engineer)

    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_name: "purge-branch",
        worktree_path: worktree_path,
        scratch_path: scratch_dir
      })

    expect(Git, :remove_worktree, fn ^clone_path, ^worktree_path -> :ok end)
    expect(Git, :delete_branch, fn ^clone_path, "purge-branch" -> :ok end)

    assert :ok = Pipeline.purge_task(task)

    refute File.exists?(scratch_dir)
  end
end
