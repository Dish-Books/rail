defmodule Rail.Issues.Actions.ListTrackerMovesTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Workers.MoveToLocalTracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    projects =
      for n <- 1..2 do
        Repo.insert!(%Project{
          name: "Moves Project #{n}",
          github_repo: "org/moves-#{n}",
          github_installation_id: 1,
          default_branch: "main",
          key: "MOV#{n}",
          linear_team_id: "lin_team_mov#{n}",
          linear_workspace_id: "lw_test_seed",
          clone_path: "/tmp/repos/moves-#{n}"
        })
      end

    %{projects: projects, scope: user_scope(admin: true)}
  end

  test "a project with no move is left out, and a queued or running move reads moving", %{
    projects: [%Project{id: queued_id} = queued, %Project{id: running_id} = running],
    scope: scope
  } do
    assert {:ok, %{}} = Issues.list_tracker_moves(scope, [queued, running])

    {:ok, _queued} = Oban.insert(MoveToLocalTracker.new(%{project_id: queued_id}))
    {:ok, %Oban.Job{id: job_id}} = Oban.insert(MoveToLocalTracker.new(%{project_id: running_id}))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id), set: [state: "executing"])

    assert {:ok, %{^queued_id => :moving, ^running_id => :moving}} =
             Issues.list_tracker_moves(scope, [queued, running])
  end

  test "a failure sentence reads stopped with it, even while Oban still has the job running", %{
    projects: [%Project{id: project_id} = project | _rest],
    scope: scope
  } do
    {:ok, %Oban.Job{id: job_id}} = Oban.insert(MoveToLocalTracker.new(%{project_id: project_id}))

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id),
      set: [state: "executing", meta: %{"failure" => "Linear answered 502 while reading comments."}]
    )

    assert {:ok, %{^project_id => {:stopped, "Linear answered 502 while reading comments."}}} =
             Issues.list_tracker_moves(scope, [project])
  end

  test "a move discarded with no sentence stopped unexpectedly, and a newer move reads on its own", %{
    projects: [%Project{id: project_id} = project | _rest],
    scope: scope
  } do
    {:ok, %Oban.Job{id: job_id}} = Oban.insert(MoveToLocalTracker.new(%{project_id: project_id}))
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id), set: [state: "discarded"])

    assert {:ok, %{^project_id => {:stopped, "The move stopped unexpectedly, before it could say why."}}} =
             Issues.list_tracker_moves(scope, [project])

    {:ok, _retry} = Oban.insert(MoveToLocalTracker.new(%{project_id: project_id}))

    assert {:ok, %{^project_id => :moving}} = Issues.list_tracker_moves(scope, [project])
  end

  test "a project on Rail reads moved, and a finished move on a project still on Linear is left out", %{
    projects: [%Project{id: moved_id} = moved, %Project{id: other_id} = other],
    scope: scope
  } do
    for project_id <- [moved_id, other_id] do
      {:ok, %Oban.Job{id: job_id}} = Oban.insert(MoveToLocalTracker.new(%{project_id: project_id}))
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job_id), set: [state: "completed"])
    end

    assert {:ok, moves} = Issues.list_tracker_moves(scope, [%{moved | tracker: :local}, other])
    assert %{^moved_id => :moved} = moves
    refute Map.has_key?(moves, other_id)
  end

  test "only an admin can read moves", %{projects: projects} do
    assert {:error, :not_authorized} = Issues.list_tracker_moves(user_scope(), projects)
  end
end
