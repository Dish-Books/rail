defmodule Rail.Pipeline.Actions.MergeTaskTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.GitHub
  import RailTest.Mocks.Linear

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Merge Task Workspace",
        external_id: "lin_ws_merge_task",
        token: "lin_api_token_merge_task",
        webhook_secret: "whsec_merge_task"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9201",
        github_repo: "org/merge-task-9201",
        github_installation_id: 9201,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_merge_task_9201",
        linear_team_key: "P9201",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9201",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_merge_task_1",
      "identifier" => "MGT-1",
      "title" => "Merge Task Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Merge Task Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns {:ok, _task} when task is already merged", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9202",
        github_repo: "org/merge-task-9202",
        github_installation_id: 9202,
        linear_team_id: "team_merge_task_9202",
        linear_team_key: "P9202",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9202",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9203",
      "identifier" => "TSK-9203",
      "title" => "Task 9203"
    })

    {:ok, issue_9203} = Issues.capture_issue(system_scope(), project, "Task 9203")

    {:ok, task} = Pipeline.create_task(issue_9203, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :merged,
        pr_number: 100
      })

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task)
  end

  test "returns {:error, :no_pr} when task has no pr_number", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9204",
        github_repo: "org/merge-task-9204",
        github_installation_id: 9204,
        linear_team_id: "team_merge_task_9204",
        linear_team_key: "P9204",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9204",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9205",
      "identifier" => "TSK-9205",
      "title" => "Task 9205"
    })

    {:ok, issue_9205} = Issues.capture_issue(system_scope(), project, "Task 9205")

    {:ok, task} = Pipeline.create_task(issue_9205, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: nil
      })

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, :no_pr} = Pipeline.merge_task(task)
  end

  test "returns {:error, :draft_pr} when pull request is still a draft", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9206",
        github_repo: "org/merge-task-9206",
        github_installation_id: 9206,
        linear_team_id: "team_merge_task_9206",
        linear_team_key: "P9206",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9206",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9207",
      "identifier" => "TSK-9207",
      "title" => "Task 9207"
    })

    {:ok, issue_9207} = Issues.capture_issue(system_scope(), project, "Task 9207")

    {:ok, task} = Pipeline.create_task(issue_9207, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 101,
        pr_is_draft: true
      })

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, :draft_pr} = Pipeline.merge_task(task)
  end

  test "returns {:error, :has_conflicts} when PR has conflicts and ignore_conflicts is false", %{
    project: _project,
    task: _task
  } do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9208",
        github_repo: "org/merge-task-9208",
        github_installation_id: 9208,
        linear_team_id: "team_merge_task_9208",
        linear_team_key: "P9208",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9208",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9209",
      "identifier" => "TSK-9209",
      "title" => "Task 9209"
    })

    {:ok, issue_9209} = Issues.capture_issue(system_scope(), project, "Task 9209")

    {:ok, task} = Pipeline.create_task(issue_9209, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 102,
        pr_is_draft: false,
        mergeability: :conflicting
      })

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, :has_conflicts} = Pipeline.merge_task(task)
  end

  test "squash merges PR, deletes branch, removes worktree, and updates Linear issue to done", %{
    project: _project,
    issue: _issue,
    task: _task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    clone_path = create_temp_git_repo(prefix: "rail_merge_main")
    wt_dir = Path.join(System.tmp_dir!(), "rail_merge_wt_#{System.unique_integer([:positive])}")

    {:ok, worktree_path} =
      Git.get_or_create_worktree(%Project{clone_path: clone_path, default_branch: "main"}, %Task{
        worktree_path: wt_dir,
        worktree_name: "feature-branch"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9210",
        github_repo: "testorg/merge_repo",
        github_installation_id: 9210,
        linear_team_id: "team_merge_task_9210",
        linear_team_key: "P9210",
        default_branch: "main",
        clone_path: clone_path,
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_merge_task_9211",
        login: "merge_task_user_9211",
        email: "merge_task_user_9211@example.com",
        github_token: "gho_merger_token"
      })

    {:ok, user} =
      Users.link_linear(user, %{
        access_token: "lin_merger_token",
        refresh_token: "lin_refresh_9211",
        expires_in: 3600
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_iss_ext_1",
      "identifier" => "ISS-9212",
      "title" => "Merge Task Issue 9212"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Merge Task Issue 9212")

    LinearMock.mock_update_issue_success(%{"id" => "lin_iss_ext_1"})

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        state: :in_progress,
        branch_name: "feature-branch"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9213",
      "identifier" => "TSK-9213",
      "title" => "Task 9213"
    })

    {:ok, issue_9213} = Issues.capture_issue(system_scope(), project, "Task 9213")

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_9213, :product)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        owner_user_id: user.id,
        stage: :ready_to_merge,
        pr_number: 200,
        pr_is_draft: false,
        mergeability: :mergeable,
        worktree_name: "feature-branch",
        worktree_path: worktree_path
      })

    mock_installation_token_success(installation_id: 9210)

    mock_merge_pull_request_success("testorg/merge_repo", 200,
      user_token: "mock_installation_token",
      merge_method: "squash"
    )

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

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:ok, %Task{stage: :merged, merged_at: %DateTime{}, error: nil}} =
             Pipeline.merge_task(task, [])

    refute File.exists?(worktree_path)

    reloaded_issue = Repo.get!(Issue, issue.id)
    assert reloaded_issue.state == :done

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :task_merged}}
  end

  test "merges conflicting PR when ignore_conflicts: true is supplied", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9214",
        github_repo: "testorg/merge_conflicted",
        github_installation_id: 9214,
        linear_team_id: "team_merge_task_9214",
        linear_team_key: "P9214",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9214",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9215",
      "identifier" => "TSK-9215",
      "title" => "Task 9215"
    })

    {:ok, issue_9215} = Issues.capture_issue(system_scope(), project, "Task 9215")

    {:ok, task} = Pipeline.create_task(issue_9215, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 201,
        pr_is_draft: false,
        mergeability: :conflicting,
        worktree_name: "conflicted-branch"
      })

    mock_merge_pull_request_success("testorg/merge_conflicted", 201)
    mock_delete_remote_branch_success("testorg/merge_conflicted", "conflicted-branch")

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:ok, %Task{stage: :merged}} =
             Pipeline.merge_task(task, ignore_conflicts: true, token: "tok_test")
  end

  test "double checks pull_request_is_merged when merge returns error", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9216",
        github_repo: "testorg/double_check",
        github_installation_id: 9216,
        linear_team_id: "team_merge_task_9216",
        linear_team_key: "P9216",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9216",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9217",
      "identifier" => "TSK-9217",
      "title" => "Task 9217"
    })

    {:ok, issue_9217} = Issues.capture_issue(system_scope(), project, "Task 9217")

    {:ok, task} = Pipeline.create_task(issue_9217, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 202,
        pr_is_draft: false,
        worktree_name: "branch-202"
      })

    mock_merge_pull_request_error("testorg/double_check", 202, 405, "Method Not Allowed")
    mock_pull_request_is_merged_success("testorg/double_check", 202, true)
    mock_delete_remote_branch_success("testorg/double_check", "branch-202")

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task, token: "tok_test")
  end

  test "records error and fails when merge fails and PR was not merged", %{project: _project, task: _task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9218",
        github_repo: "testorg/failed_merge",
        github_installation_id: 9218,
        linear_team_id: "team_merge_task_9218",
        linear_team_key: "P9218",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9218",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9219",
      "identifier" => "TSK-9219",
      "title" => "Task 9219"
    })

    {:ok, issue_9219} = Issues.capture_issue(system_scope(), project, "Task 9219")

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_9219, :product)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 203,
        pr_is_draft: false
      })

    mock_merge_pull_request_error("testorg/failed_merge", 203, 405, "Method Not Allowed")
    mock_pull_request_is_merged_success("testorg/failed_merge", 203, false)

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, {:github_api_error, 405, _body}} = Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task_id)
    assert reloaded.error =~ "Failed to merge pull request: Method Not Allowed"

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :merge_failed}}
  end

  test "returns error when project is not found", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9220",
        github_repo: "org/merge-task-9220",
        github_installation_id: 9220,
        linear_team_id: "team_merge_task_9220",
        linear_team_key: "P9220",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9220",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9221",
      "identifier" => "TSK-9221",
      "title" => "Task 9221"
    })

    {:ok, issue_9221} = Issues.capture_issue(system_scope(), project, "Task 9221")

    {:ok, task} = Pipeline.create_task(issue_9221, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        pr_number: 204,
        pr_is_draft: false
      })

    Repo.delete!(project)

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, :project_not_found} = Pipeline.merge_task(task)
  end

  test "deletes the remote branch named by the task worktree", %{project: _project, issue: _issue, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9222",
        github_repo: "testorg/branch_from_issue",
        github_installation_id: 9222,
        linear_team_id: "team_merge_task_9222",
        linear_team_key: "P9222",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9222",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_merge_task_9223",
      "identifier" => "ISS-9223",
      "title" => "Merge Task Issue 9223"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Merge Task Issue 9223")

    {:ok, issue} =
      Issues.update_issue(system_scope(), issue, %{
        branch_name: "issue-branch-name"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9224",
      "identifier" => "TSK-9224",
      "title" => "Task 9224"
    })

    {:ok, issue_9224} = Issues.capture_issue(system_scope(), project, "Task 9224")

    {:ok, task} = Pipeline.create_task(issue_9224, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        stage: :ready_to_merge,
        pr_number: 301,
        pr_is_draft: false,
        worktree_name: "removed-worktree",
        worktree_path: "/tmp/rail-removed-worktree"
      })

    mock_merge_pull_request_success("testorg/branch_from_issue", 301)
    mock_delete_remote_branch_success("testorg/branch_from_issue", "removed-worktree")

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task, token: "tok_test")
  end

  test "merges successfully when task has no issue_id", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9225",
        github_repo: "testorg/no_issue",
        github_installation_id: 9225,
        linear_team_id: "team_merge_task_9225",
        linear_team_key: "P9225",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9225",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9226",
      "identifier" => "TSK-9226",
      "title" => "Task 9226"
    })

    {:ok, issue_9226} = Issues.capture_issue(system_scope(), project, "Task 9226")

    {:ok, task} = Pipeline.create_task(issue_9226, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        issue_id: nil,
        stage: :ready_to_merge,
        pr_number: 302,
        pr_is_draft: false,
        worktree_name: "removed-worktree",
        worktree_path: "/tmp/rail-removed-worktree"
      })

    mock_merge_pull_request_success("testorg/no_issue", 302)
    mock_delete_remote_branch_success("testorg/no_issue", "removed-worktree")

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:ok, %Task{stage: :merged}} = Pipeline.merge_task(task, token: "tok_test")
  end

  test "formats error reason with map message", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9227",
        github_repo: "testorg/map_error",
        github_installation_id: 9227,
        linear_team_id: "team_merge_task_9227",
        linear_team_key: "P9227",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9227",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9228",
      "identifier" => "TSK-9228",
      "title" => "Task 9228"
    })

    {:ok, issue_9228} = Issues.capture_issue(system_scope(), project, "Task 9228")

    {:ok, task} = Pipeline.create_task(issue_9228, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
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

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, {:github_api_error, 422, %{"message" => "Validation Failed"}}} =
             Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error == "Failed to merge pull request: Validation Failed"
  end

  test "formats error reason with string message", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9231",
        github_repo: "testorg/string_error",
        github_installation_id: 9231,
        linear_team_id: "team_merge_task_9231",
        linear_team_key: "P9231",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9231",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9232",
      "identifier" => "TSK-9232",
      "title" => "Task 9232"
    })

    {:ok, issue_9232} = Issues.capture_issue(system_scope(), project, "Task 9232")

    {:ok, task} = Pipeline.create_task(issue_9232, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
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

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, {:github_api_error, 500, "Internal Server Error"}} =
             Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error == "Failed to merge pull request: 500 Internal Server Error"
  end

  test "formats error reason with arbitrary error", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merge Task Project 9233",
        github_repo: "testorg/arbitrary_error",
        github_installation_id: 9233,
        linear_team_id: "team_merge_task_9233",
        linear_team_key: "P9233",
        default_branch: "main",
        clone_path: "/tmp/repos/merge-task-9233",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_merge_task_9234",
      "identifier" => "TSK-9234",
      "title" => "Task 9234"
    })

    {:ok, issue_9234} = Issues.capture_issue(system_scope(), project, "Task 9234")

    {:ok, task} = Pipeline.create_task(issue_9234, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 306,
        pr_is_draft: false
      })

    Req.Test.expect(Rail.GitHub, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    mock_pull_request_is_merged_success("testorg/arbitrary_error", 306, false)

    LinearMock.mock_update_issue_success(%{"id" => "lin_merge_done"})

    assert {:error, %Req.TransportError{reason: :timeout}} = Pipeline.merge_task(task, token: "tok_test")

    reloaded = Repo.get!(Task, task.id)
    assert reloaded.error =~ "Failed to merge pull request: %Req.TransportError{reason: :timeout}"
  end
end
