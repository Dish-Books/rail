defmodule Rail.Pipeline.Actions.CleanupTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Cleanup Task Workspace",
        external_id: "lin_ws_cleanup_task",
        token: "lin_api_token_cleanup_task",
        webhook_secret: "whsec_cleanup_task"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cleanup Task Project 8701",
        github_repo: "org/cleanup-task-8701",
        github_installation_id: 8701,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_cleanup_task_8701",
        linear_team_key: "P8701",
        clone_path: "/tmp/repos/cleanup-task-8701",
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
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_cleanup_task_1",
      "identifier" => "CLT-1",
      "title" => "Cleanup Task Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Cleanup Task Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "refuses to clean up when task is busy", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cleanup Task Project 8702",
        github_repo: "org/cleanup-task-8702",
        github_installation_id: 8702,
        linear_team_id: "team_cleanup_task_8702",
        linear_team_key: "P8702",
        clone_path: "/tmp/repos/cleanup-task-8702",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cleanup_task_8703",
      "identifier" => "TSK-8703",
      "title" => "Task 8703"
    })

    {:ok, issue_8703} = Issues.capture_issue(system_scope(), project, "Task 8703")

    {:ok, task} = Pipeline.create_task(issue_8703, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    assert {:error, :task_busy} = Pipeline.cleanup_task(task)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cleanup_task_8704",
      "identifier" => "TSK-8704",
      "title" => "Task 8704"
    })

    {:ok, issue_8704} = Issues.capture_issue(system_scope(), project, "Task 8704")

    {:ok, task_chat} = Pipeline.create_task(issue_8704, :product)

    {:ok, task_chat} =
      Pipeline.update_task(system_scope(), task_chat.id, %{
        stage: :qa,
        stage_state: :awaiting_approval,
        active_chat_role_id: "qa"
      })

    assert {:error, :task_busy} = Pipeline.cleanup_task(task_chat)
  end

  test "cleans up worktree, branch and scratch directory, and broadcasts", %{
    project: _project,
    task: _task
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    clone_path = create_temp_git_repo(prefix: "rail_cleanup_main")
    wt_dir = Path.join(System.tmp_dir!(), "rail_cleanup_wt_#{System.unique_integer([:positive])}")

    {:ok, worktree_path} =
      Git.get_or_create_worktree(%Project{clone_path: clone_path}, %Task{
        worktree_path: wt_dir,
        worktree_name: "cleanup-branch"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cleanup Task Project 8705",
        github_repo: "org/cleanup-task-8705",
        github_installation_id: 8705,
        linear_team_id: "team_cleanup_task_8705",
        linear_team_key: "P8705",
        clone_path: clone_path,
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    scratch_dir = Path.join(System.tmp_dir!(), "rail_cleanup_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    File.write!(Path.join(scratch_dir, "scratch.txt"), "temporary content")

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_cleanup_task_8706",
        login: "cleanup_task_user_8706",
        email: "cleanup_task_user_8706@example.com"
      })

    scope = Scope.for_user(user)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cleanup_task_8707",
      "identifier" => "TSK-8707",
      "title" => "Task 8707"
    })

    {:ok, issue_8707} = Issues.capture_issue(system_scope(), project, "Task 8707")

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_8707, :product)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :merged,
        stage_state: :queued,
        worktree_name: "cleanup-branch",
        worktree_path: worktree_path
      })

    assert {:ok, %Task{worktree_path: ^worktree_path} = cleaned} =
             Pipeline.cleanup_task(scope, task, scratch_dir: scratch_dir)

    refute Task.worktree_present?(cleaned)

    refute File.exists?(worktree_path)
    refute File.exists?(scratch_dir)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :task_cleaned_up}}
  end

  test "handles cleanup gracefully when worktree_path is already nil", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cleanup Task Project 8708",
        github_repo: "org/cleanup-task-8708",
        github_installation_id: 8708,
        linear_team_id: "team_cleanup_task_8708",
        linear_team_key: "P8708",
        clone_path: "/tmp/repos/cleanup-task-8708",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cleanup_task_8709",
      "identifier" => "TSK-8709",
      "title" => "Task 8709"
    })

    {:ok, issue_8709} = Issues.capture_issue(system_scope(), project, "Task 8709")

    {:ok, task} = Pipeline.create_task(issue_8709, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :merged,
        worktree_name: "removed-worktree",
        worktree_path: "/tmp/rail-removed-worktree"
      })

    assert {:ok, %Task{}} = Pipeline.cleanup_task(task)
  end

  test "returns error when scope is unauthorized" do
    assert {:error, :not_authorized} = Pipeline.cleanup_task(:unauthorized, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.cleanup_task("tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.cleanup_task(123)
  end

  test "accepts nil scope and task with opts", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Cleanup Task Project 8710",
        github_repo: "org/cleanup-task-8710",
        github_installation_id: 8710,
        linear_team_id: "team_cleanup_task_8710",
        linear_team_key: "P8710",
        clone_path: "/tmp/repos/cleanup-task-8710",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_cleanup_task_8711",
      "identifier" => "TSK-8711",
      "title" => "Task 8711"
    })

    {:ok, issue_8711} = Issues.capture_issue(system_scope(), project, "Task 8711")

    {:ok, task} = Pipeline.create_task(issue_8711, :product)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :merged,
        worktree_name: "removed-worktree",
        worktree_path: "/tmp/rail-removed-worktree"
      })

    assert {:ok, %Task{}} = Pipeline.cleanup_task(nil, task)
    assert {:ok, %Task{}} = Pipeline.cleanup_task(task.id, scratch_dir: "/tmp/nonexistent")
  end
end
