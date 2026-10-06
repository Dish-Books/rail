defmodule Rail.Pipeline.Actions.DiscardTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles

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

    assert :ok = Pipeline.discard_task(task)

    assert %Run{status: :finished} = Repo.get(Run, running_id)
    assert %Run{status: :failed} = Repo.get(Run, failed_id)
    assert %Task{id: ^task_id, cleaned_up_at: nil} = Repo.get(Task, task_id)
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
