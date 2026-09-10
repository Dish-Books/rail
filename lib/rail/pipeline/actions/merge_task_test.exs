defmodule Rail.Pipeline.Actions.MergeTaskTest do
  use Rail.DataCase, async: false

  import RailTest.Mocks.GitHub
  import RailTest.Mocks.Linear

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "returns {:ok, task} when task is already merged" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :merged,
          pr_number: 100
      })

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task)
  end

  test "returns {:error, :no_pr} when task has no pr_number" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: nil
      })

    assert {:error, :no_pr} = Pipeline.merge_task(task)
  end

  test "returns {:error, :draft_pr} when pull request is still a draft" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 101,
          pr_is_draft: true
      })

    assert {:error, :draft_pr} = Pipeline.merge_task(task)
  end

  test "returns {:error, :has_conflicts} when PR has conflicts and ignore_conflicts is false" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 102,
          pr_is_draft: false,
          mergeability: :conflicting
      })

    assert {:error, :has_conflicts} = Pipeline.merge_task(task)
  end

  test "squash merges PR, deletes branch, removes worktree, and updates Linear issue to done" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    clone_path = create_temp_git_repo(prefix: "rail_merge_main")
    wt_dir = Path.join(System.tmp_dir!(), "rail_merge_wt_#{System.unique_integer([:positive])}")
    {:ok, worktree_path} = Git.get_or_create_worktree(clone_path, wt_dir, "feature-branch")

    project =
      Repo.insert!(%{
        Project.factory()
        | github_repo: "testorg/merge_repo",
          clone_path: clone_path
      })

    user =
      Repo.insert!(%{
        User.factory()
        | github_token: "gho_merger_token",
          linear_access_token: "lin_merger_token",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
      })

    issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_iss_ext_1",
          state: :in_progress,
          branch_name: "feature-branch"
      })

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          issue_id: issue.id,
          owner_user_id: user.id,
          stage: :ready_to_merge,
          pr_number: 200,
          pr_is_draft: false,
          mergeability: :mergeable,
          worktree_name: "feature-branch",
          worktree_path: worktree_path
      })

    mock_merge_pull_request_success("testorg/merge_repo", 200, user_token: "gho_merger_token", merge_method: "squash")
    mock_delete_remote_branch_success("testorg/merge_repo", "feature-branch")

    mock_update_issue_success(%{
      "id" => "lin_iss_ext_1",
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"},
      "branchName" => "feature-branch",
      "url" => issue.url,
      "createdAt" => "2026-09-01T10:00:00.000Z",
      "updatedAt" => "2026-09-09T17:00:00.000Z"
    })

    scope = Scope.for_user(user)

    assert {:ok, %Task{stage: :merged, worktree_path: nil, merged_at: %DateTime{}, error: nil}} =
             Pipeline.merge_task(scope, task, [])

    refute File.exists?(worktree_path)

    reloaded_issue = Repo.get!(Issue, issue.id)
    assert reloaded_issue.state == :done

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :task_merged}}
  end

  test "merges conflicting PR when ignore_conflicts: true is supplied" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/merge_conflicted"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 201,
          pr_is_draft: false,
          mergeability: :conflicting,
          worktree_name: "conflicted-branch"
      })

    mock_merge_pull_request_success("testorg/merge_conflicted", 201)
    mock_delete_remote_branch_success("testorg/merge_conflicted", "conflicted-branch")

    assert {:ok, %Task{stage: :merged}} =
             Pipeline.merge_task(task, ignore_conflicts: true, token: "tok_test")
  end

  test "double checks pull_request_is_merged when merge returns error" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/double_check"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 202,
          pr_is_draft: false,
          worktree_name: "branch-202"
      })

    mock_merge_pull_request_error("testorg/double_check", 202, 405, "Method Not Allowed")
    mock_pull_request_is_merged_success("testorg/double_check", 202, true)
    mock_delete_remote_branch_success("testorg/double_check", "branch-202")

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task, token: "tok_test")
  end

  test "records error and fails when merge fails and PR was not merged" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/failed_merge"})

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 203,
          pr_is_draft: false
      })

    mock_merge_pull_request_error("testorg/failed_merge", 203, 405, "Method Not Allowed")
    mock_pull_request_is_merged_success("testorg/failed_merge", 203, false)

    assert {:error, {:github_api_error, 405, _body}} = Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task_id)
    assert reloaded.error =~ "Failed to merge pull request: Method Not Allowed"

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :merge_failed}}
  end

  test "returns error when scope is unauthorized" do
    assert {:error, :not_authorized} = Pipeline.merge_task(:invalid_scope, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.merge_task("tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.merge_task(123)
  end

  test "returns error when project is not found" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          pr_number: 204,
          pr_is_draft: false
      })

    Repo.delete!(project)

    assert {:error, :project_not_found} = Pipeline.merge_task(task)
  end

  test "deletes remote branch from issue when worktree_name is nil" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/branch_from_issue"})
    issue = Repo.insert!(%{Issue.factory() | project_id: project.id, branch_name: "issue-branch-name"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          issue_id: issue.id,
          stage: :ready_to_merge,
          pr_number: 301,
          pr_is_draft: false,
          worktree_name: nil,
          worktree_path: nil
      })

    mock_merge_pull_request_success("testorg/branch_from_issue", 301)
    mock_delete_remote_branch_success("testorg/branch_from_issue", "issue-branch-name")

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task, token: "tok_test")
  end

  test "merges successfully when task has no issue_id" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/no_issue"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          issue_id: nil,
          stage: :ready_to_merge,
          pr_number: 302,
          pr_is_draft: false,
          worktree_name: nil,
          worktree_path: nil
      })

    mock_merge_pull_request_success("testorg/no_issue", 302)

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task, token: "tok_test")
  end

  test "formats error reason with map message" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/map_error"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 303,
          pr_is_draft: false
      })

    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(422, Jason.encode!(%{"message" => "Validation Failed"}))
    end)

    mock_pull_request_is_merged_success("testorg/map_error", 303, false)

    assert {:error, {:github_api_error, 422, %{"message" => "Validation Failed"}}} =
             Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error == "Failed to merge pull request: Validation Failed"
  end

  test "accepts nil scope during merge" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/nil_scope"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 304,
          pr_is_draft: false,
          worktree_name: nil
      })

    mock_merge_pull_request_success("testorg/nil_scope", 304)

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(nil, task, token: "tok_test")
  end

  test "formats error reason with string message" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/string_error"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 305,
          pr_is_draft: false
      })

    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(500, "Internal Server Error")
    end)

    mock_pull_request_is_merged_success("testorg/string_error", 305, false)

    assert {:error, {:github_api_error, 500, "Internal Server Error"}} =
             Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error == "Failed to merge pull request: 500 Internal Server Error"
  end

  test "formats error reason with arbitrary error" do
    project = Repo.insert!(%{Project.factory() | github_repo: "testorg/arbitrary_error"})

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 306,
          pr_is_draft: false
      })

    Req.Test.expect(Rail.GitHub, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    mock_pull_request_is_merged_success("testorg/arbitrary_error", 306, false)

    assert {:error, %Req.TransportError{reason: :timeout}} = Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error =~ "Failed to merge pull request: %Req.TransportError{reason: :timeout}"
  end
end
