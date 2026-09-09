defmodule Rail.Pipeline.Actions.MarkPrReadyTest do
  use Rail.DataCase, async: false

  import RailTest.Mocks.GitHub

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "returns :no_pr and records error when task has no pr_number" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = Repo.insert!(Project.factory())

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: nil,
          pr_is_draft: true
      })

    assert {:error, :no_pr} = Pipeline.mark_pr_ready(task)

    reloaded = Repo.get!(Task, task_id)
    assert reloaded.error == "This task has no pull request to mark ready."

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :mark_pr_ready_failed}}
  end

  test "promotes draft PR, clears error, and triggers mergeability refresh" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/markready"})
    user = Repo.insert!(%{User.factory() | github_token: "gho_ready_token"})

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 123,
          pr_is_draft: true,
          error: "Previous error",
          mergeability: :unknown
      })

    mock_mark_pull_request_ready_success("testorg/markready", 123, user_token: "gho_ready_token")
    mock_pull_request_state_success("testorg/markready", 123, mergeable: true, draft: false)

    scope = Scope.for_user(user)

    assert {:ok, %Task{pr_is_draft: false, error: nil, mergeability: :mergeable}} =
             Pipeline.mark_pr_ready(scope, task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :pr_marked_ready}}
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :mergeability_refreshed}}
  end

  test "records error and leaves draft status true when GitHub mark ready fails" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/markready"})

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 124,
          pr_is_draft: true
      })

    mock_mark_pull_request_ready_mutation_http_error("testorg/markready", 124, 422, "Draft cannot be converted")

    assert {:error, {:github_api_error, 422, %{"message" => "Draft cannot be converted"}}} =
             Pipeline.mark_pr_ready(nil, task.id, token: "tok_test")

    reloaded = Repo.get!(Task, task_id)
    assert reloaded.pr_is_draft == true
    assert reloaded.error == "Failed to mark pull request ready: Draft cannot be converted"

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :mark_pr_ready_failed}}
  end

  test "records error when GitHub returns binary error message" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/markready"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 126,
          pr_is_draft: true
      })

    mock_mark_pull_request_ready_query_not_found("testorg/markready", 126)

    assert {:error, {:github_api_error, 404, "Repository not found"}} =
             Pipeline.mark_pr_ready(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error == "Failed to mark pull request ready: 404 Repository not found"
  end

  test "records error when GitHub returns graphql error" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/markready"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 127,
          pr_is_draft: true
      })

    mock_mark_pull_request_ready_graphql_error("Some GraphQL failure")

    assert {:error, {:github_graphql_error, _errors}} =
             Pipeline.mark_pr_ready(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error =~ "Failed to mark pull request ready: {:github_graphql_error,"
  end

  test "returns error when scope is unauthorized" do
    assert {:error, :not_authorized} = Pipeline.mark_pr_ready(:unauthorized, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.mark_pr_ready("tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.mark_pr_ready(123)
  end

  test "returns error when project is not found" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          pr_number: 125
      })

    Repo.delete!(project)

    assert {:error, :project_not_found} = Pipeline.mark_pr_ready(task)
  end
end
