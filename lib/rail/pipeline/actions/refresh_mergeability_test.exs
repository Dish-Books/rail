defmodule Rail.Pipeline.Actions.RefreshMergeabilityTest do
  use Rail.DataCase, async: false

  import RailTest.Mocks.GitHub

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "skips refresh when task is merged" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :merged,
          pr_number: 101,
          mergeability: :mergeable,
          pr_is_draft: false
      })

    assert {:ok, %Task{stage: :merged}} = Pipeline.refresh_mergeability(task)
  end

  test "skips refresh when task has no pr_number" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :review,
          pr_number: nil,
          mergeability: nil,
          pr_is_draft: false
      })

    assert {:ok, %Task{pr_number: nil}} = Pipeline.refresh_mergeability(task)
  end

  test "updates mergeability and draft status on successful poll" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/testrepo"})
    user = Repo.insert!(%{User.factory() | github_token: "gho_test_user_tok"})

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 42,
          mergeability: :unknown,
          pr_is_draft: true
      })

    mock_pull_request_state_success("testorg/testrepo", 42, mergeable: true, draft: false)

    scope = Scope.for_user(user)
    assert {:ok, %Task{mergeability: :mergeable, pr_is_draft: false}} = Pipeline.refresh_mergeability(scope, task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :mergeability_refreshed}}
  end

  test "preserves conflicting status when GitHub returns unknown" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/testrepo"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 55,
          mergeability: :conflicting,
          pr_is_draft: false
      })

    mock_pull_request_state_success("testorg/testrepo", 55, mergeable: nil, draft: false)

    assert {:ok, %Task{mergeability: :conflicting, pr_is_draft: false}} =
             Pipeline.refresh_mergeability(task, token: "tok_test", attempts: 1, retry_delay_ms: 0)
  end

  test "preserves existing pr_is_draft when GitHub returns nil draft status" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/testrepo"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 66,
          mergeability: :unknown,
          pr_is_draft: true
      })

    mock_pull_request_state_success("testorg/testrepo", 66, mergeable: true, draft: nil)

    assert {:ok, %Task{mergeability: :mergeable, pr_is_draft: true}} =
             Pipeline.refresh_mergeability(nil, task.id, token: "tok_test")
  end

  test "returns error when scope is unauthorized" do
    assert {:error, :not_authorized} = Pipeline.refresh_mergeability(:invalid_scope, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.refresh_mergeability("tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.refresh_mergeability(123)
  end

  test "returns error when project is not found" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          pr_number: 99
      })

    Repo.delete!(project)

    assert {:error, :project_not_found} = Pipeline.refresh_mergeability(task)
  end

  test "returns error when token cannot be resolved" do
    mock_installation_token_error(401, "Bad credentials", installation_id: 12_345)
    project = Repo.insert!(%{Project.factory() | github_installation_id: 12_345})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          pr_number: 88
      })

    assert {:error, {:github_api_error, 401, _body}} = Pipeline.refresh_mergeability(task)
  end

  test "returns error when GitHub client returns error" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/testrepo"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          pr_number: 77
      })

    mock_pull_request_state_error("testorg/testrepo", 77, 404, "Not Found")

    assert {:error, {:github_api_error, 404, _body}} =
             Pipeline.refresh_mergeability(task, token: "tok_test")
  end

  test "checks demo staleness and re-queues ready_to_merge task when commit drifted" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/testrepo"})
    worktree = create_temp_git_repo()

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          stage_state: :awaiting_approval,
          pr_number: 99,
          worktree_path: worktree
      })

    create_test_demo(%{
      task_id: task.id,
      version: 1,
      stale: false,
      head_sha: "old_head_sha"
    })

    mock_pull_request_state_success("testorg/testrepo", 99, mergeable: true, draft: false)

    assert {:ok, %Task{stage: :demo, stage_state: :queued, mergeability: :mergeable}} =
             Pipeline.refresh_mergeability(task, token: "tok_test")
  end
end
