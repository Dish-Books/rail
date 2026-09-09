defmodule Rail.Pipeline.Actions.BringLocalTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User
  alias RailTest.Mocks.Linear, as: LinearMock

  test "returns not_authorized error for nil or unauthenticated scope" do
    issue = %Issue{id: "iss_123"}
    assert {:error, :not_authorized} = Pipeline.bring_local(nil, issue)
    assert {:error, :not_authorized} = Pipeline.bring_local(%Scope{user: nil, system: false}, issue)
  end

  test "returns existing task if already brought local (idempotency)" do
    project = create_test_project()
    issue = Repo.insert!(Issue.changeset(Issue.factory(), %{}, project.id))
    %Task{id: existing_id} = create_test_task(%{project_id: project.id, issue_id: issue.id})

    scope = Scope.for_system()

    assert {:ok, %Task{id: ^existing_id}} = Pipeline.bring_local(scope, issue)
  end

  test "brings issue local, updates Linear state, creates task, and broadcasts event" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_bring_1",
          linear_state_ids: %{"in_progress" => "st_in_prog_1"}
      })

    %Issue{id: issue_id} =
      issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_bring_1",
          identifier: "ENG-5001",
          title: "Implement Core Pipeline",
          description: "Full bring_local integration",
          branch_name: "eng-5001-pipeline",
          state: :triage
      })

    %User{id: user_id} = user = Repo.insert!(User.factory())
    scope = Scope.for_user(user)

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_bring_1",
      "identifier" => "ENG-5001",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_in_prog_1", "name" => "In Progress", "type" => "started"},
      "branchName" => "eng-5001-pipeline",
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    assert {:ok,
            %Task{
              id: task_id,
              issue_id: ^issue_id,
              owner_user_id: ^user_id,
              title: "Implement Core Pipeline",
              description: "Full bring_local integration",
              stage: :product,
              stage_state: :queued,
              worktree_name: "eng-5001-pipeline"
            }} = Pipeline.bring_local(scope, issue, user)

    # Verify PubSub broadcast
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :brought_local}}
  end

  test "derives worktree name from identifier when branch_name is nil" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_bring_2",
          linear_state_ids: %{"in_progress" => "st_in_prog_2"}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_bring_2",
          identifier: "PROJ/FEAT #42",
          title: "Special Identifier",
          branch_name: nil,
          state: :backlog
      })

    scope = Scope.for_system()

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_bring_2",
      "identifier" => "PROJ/FEAT #42",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_in_prog_2", "name" => "In Progress", "type" => "started"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Task{worktree_name: "proj-feat--42"}} = Pipeline.bring_local(scope, issue)
  end

  test "returns error when Linear move_state fails" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_bring_err",
          linear_state_ids: %{"in_progress" => "st_in_prog_err"}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_bring_err",
          identifier: "ENG-ERR",
          state: :triage
      })

    LinearMock.mock_mutation_failure("issueUpdate")
    scope = Scope.for_system()

    assert {:error, {:linear_mutation_failed, "issueUpdate"}} = Pipeline.bring_local(scope, issue)
    assert Repo.aggregate(Task, :count, :id) == 0
  end

  test "returns existing task when already brought local" do
    project = create_test_project()

    %Issue{id: issue_id} =
      issue = Repo.insert!(%{Issue.factory() | project_id: project.id, identifier: "ENG-EXIST"})

    %Task{id: existing_id} = create_test_task(%{project_id: project.id, issue_id: issue_id})
    scope = Scope.for_system()

    assert {:ok, %Task{id: ^existing_id}} = Pipeline.bring_local(scope, issue)
  end

  test "resolves owner_user_id from scope when owner_user argument is omitted" do
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())

    project =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: ws_id,
          linear_team_id: "team_bring_scope_user",
          linear_state_ids: %{"in_progress" => "st_in_prog_scope"}
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_bring_scope",
          identifier: "ENG-SCOPE",
          state: :triage
      })

    %User{id: user_id} = user = Repo.insert!(User.factory())
    scope = Scope.for_user(user)

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_bring_scope",
      "identifier" => "ENG-SCOPE",
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_in_prog_scope", "name" => "In Progress", "type" => "started"},
      "branchName" => nil,
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-04T10:00:00.000Z"
    })

    assert {:ok, %Task{owner_user_id: ^user_id}} = Pipeline.bring_local(scope, issue)
  end

  test "returns not_authorized when scope is unauthorized" do
    project = create_test_project()
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, identifier: "ENG-UNAUTH"})

    assert {:error, :not_authorized} = Pipeline.bring_local(nil, issue)
    assert {:error, :not_authorized} = Pipeline.bring_local(%Scope{user: nil, system: false}, issue)
  end
end
