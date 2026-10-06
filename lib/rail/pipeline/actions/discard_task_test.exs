defmodule Rail.Pipeline.Actions.DiscardTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools.Schemas.OsProcess

  test "stops only the runs still going and stamps nothing on the task", %{project: project} do
    {:ok, %Task{id: task_id} = task} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_discard_runs",
        identifier: "DSC-1",
        title: "Discarded",
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

    assert :ok = Pipeline.discard_task(task)

    assert_receive {:run_changed, ^running_id}
    refute_receive {:run_changed, ^failed_id}, 50
    assert %Task{id: ^task_id, cleaned_up_at: nil} = Repo.get(Task, task_id)
  end

  # Runs, designs and demos have no foreign key to tasks, so nothing else would take them.
  test "deletes the task's runs with their processes and events, and its designs and demos", %{project: project} do
    [{:ok, %Task{id: task_id} = task}, {:ok, %Task{id: other_task_id}}] =
      for external_id <- ["lin_discard_rows", "lin_discard_neighbor"] do
        %Issue{}
        |> Issue.linear_changeset(%{
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
        reserved_memory_gb: 2,
        launch: Jason.encode!(%{"executable" => "/bin/true", "args" => [], "env" => %{}, "cwd" => "/tmp"})
      })

    Pipeline.append_run_events(run_id, nil, ["working on it"])

    Repo.insert_all("designs", [
      %{id: "des_discard", task_id: task_id, canvas_url: "/canvas", inserted_at: now, updated_at: now}
    ])

    Repo.insert_all("demos", [
      %{id: "dem_discard", task_id: task_id, recorded_at: now, outcome: "passed", inserted_at: now, updated_at: now}
    ])

    assert :ok = Pipeline.discard_task(task)

    assert Repo.get(Run, run_id) == nil
    assert Repo.get(OsProcess, os_process_id) == nil
    assert [] = Repo.all(from(e in RunEvent, where: e.run_id == ^run_id))
    assert [] = Repo.all(from(d in "designs", where: d.task_id == ^task_id, select: d.id))
    assert [] = Repo.all(from(d in "demos", where: d.task_id == ^task_id, select: d.id))
    assert %Run{id: ^other_run_id} = Repo.get(Run, other_run_id)
  end

  # Its own project, because the worktree is removed from a real clone.
  test "removes the task's worktree, branch and scratch folder", %{project: %{linear_workspace_id: workspace_id}} do
    clone_path = create_temp_git_repo(prefix: "rail_discard_main")
    worktree_path = Path.join(System.tmp_dir!(), "rail_discard_wt_#{System.unique_integer([:positive])}")
    git!(clone_path, ["worktree", "add", "-b", "discard-branch", worktree_path])

    scratch_dir = Path.join(System.tmp_dir!(), "rail_discard_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    File.write!(Path.join(scratch_dir, "notes.md"), "temporary content")

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_discard"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Discard Task Project",
        github_repo: "org/discard-task",
        github_installation_id: 8706,
        linear_team_key: "DSC",
        default_branch: "main",
        clone_path: clone_path,
        linear_workspace_id: workspace_id
      })

    {:ok, task} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_discard_files",
        identifier: "DSC-2",
        title: "Discarded with its files",
        state: :in_progress
      })
      |> Repo.insert!()
      |> Repo.preload(:project)
      |> Pipeline.create_task(:engineer)

    {:ok, task} =
      Pipeline.update_task(task, %{
        worktree_name: "discard-branch",
        worktree_path: worktree_path,
        scratch_path: scratch_dir
      })

    assert :ok = Pipeline.discard_task(task)

    refute File.exists?(worktree_path)
    refute File.exists?(scratch_dir)
    assert "" = git!(clone_path, ["branch", "--list", "discard-branch"])
  end
end
