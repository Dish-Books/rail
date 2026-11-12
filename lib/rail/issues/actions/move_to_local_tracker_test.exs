defmodule Rail.Issues.Actions.MoveToLocalTrackerTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Workers.MoveToLocalTracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    project =
      Repo.insert!(%Project{
        name: "Move Action Project",
        github_repo: "org/move-action",
        github_installation_id: 1,
        default_branch: "main",
        key: "MVA",
        linear_team_id: "lin_team_mva",
        linear_workspace_id: "lw_test_seed",
        clone_path: "/tmp/repos/move-action"
      })

    %{project: project, scope: user_scope(admin: true)}
  end

  test "queues the move of a Linear project and tells open pages", %{
    project: %Project{id: project_id} = project,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "projects")

    assert {:ok, %Oban.Job{args: %{project_id: ^project_id}}} = Issues.move_to_local_tracker(scope, project)

    assert_enqueued(worker: MoveToLocalTracker, args: %{project_id: project_id})
    assert_receive {:project_changed, ^project_id}
  end

  test "a second click, even minutes later, gets the move already queued and starts none", %{
    project: %Project{id: project_id} = project,
    scope: scope
  } do
    {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(scope, project)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id),
      set: [inserted_at: DateTime.shift(DateTime.utc_now(), minute: -5)]
    )

    assert {:ok, %Oban.Job{id: ^job_id}} = Issues.move_to_local_tracker(scope, project)
    assert [%Oban.Job{id: ^job_id}] = all_enqueued(worker: MoveToLocalTracker, args: %{project_id: project_id})
  end

  test "a project another tab already moved, or that is on Rail or GitHub, gets an error and no move", %{
    project: project,
    scope: scope,
    github_project: github_project
  } do
    Repo.update_all(from(p in Project, where: p.id == ^project.id), set: [tracker: :local])

    assert {:error, :not_on_linear} = Issues.move_to_local_tracker(scope, project)
    assert {:error, :not_on_linear} = Issues.move_to_local_tracker(scope, github_project)
    refute_enqueued(worker: MoveToLocalTracker)
  end

  test "a project that is gone is not found", %{project: project, scope: scope} do
    assert {:error, :not_found} = Issues.move_to_local_tracker(scope, %{project | id: "prj_gone"})
  end

  test "only an admin can move a project", %{project: project} do
    assert {:error, :not_authorized} = Issues.move_to_local_tracker(user_scope(), project)
    refute_enqueued(worker: MoveToLocalTracker)
  end
end
