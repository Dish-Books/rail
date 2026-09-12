defmodule Rail.Pipeline.Actions.RefreshMergeabilityTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.GitHub
  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Refresh Merge Workspace",
        external_id: "lin_ws_refresh_merge",
        token: "lin_api_token_refresh_merge",
        webhook_secret: "whsec_refresh_merge"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9001",
        github_repo: "org/refresh-merge-9001",
        github_installation_id: 9001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_refresh_merge_9001",
        linear_team_key: "P9001",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9001",
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
      "id" => "lin_refresh_merge_1",
      "identifier" => "RFM-1",
      "title" => "Refresh Merge Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Refresh Merge Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "skips refresh when task is merged", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9002",
        github_repo: "org/refresh-merge-9002",
        github_installation_id: 9002,
        linear_team_id: "team_refresh_merge_9002",
        linear_team_key: "P9002",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9002",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9003",
      "identifier" => "TSK-9003",
      "title" => "Task 9003"
    })

    {:ok, issue_9003} = Issues.capture_issue(system_scope(), project, "Task 9003")

    {:ok, task} = Pipeline.create_task(issue_9003, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :merged,
        pr_number: 101,
        mergeability: :mergeable,
        pr_is_draft: false
      })

    assert {:ok, %Task{stage: :merged}} = Pipeline.refresh_mergeability(task)
  end

  test "skips refresh when task has no pr_number", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9004",
        github_repo: "org/refresh-merge-9004",
        github_installation_id: 9004,
        linear_team_id: "team_refresh_merge_9004",
        linear_team_key: "P9004",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9004",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9005",
      "identifier" => "TSK-9005",
      "title" => "Task 9005"
    })

    {:ok, issue_9005} = Issues.capture_issue(system_scope(), project, "Task 9005")

    {:ok, task} = Pipeline.create_task(issue_9005, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :review,
        pr_number: nil,
        mergeability: nil,
        pr_is_draft: false
      })

    assert {:ok, %Task{pr_number: nil}} = Pipeline.refresh_mergeability(task)
  end

  test "updates mergeability and draft status on successful poll", %{project: _project, task: _task} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9006",
        github_repo: "testorg/testrepo",
        github_installation_id: 9006,
        linear_team_id: "team_refresh_merge_9006",
        linear_team_key: "P9006",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9006",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9008",
      "identifier" => "TSK-9008",
      "title" => "Task 9008"
    })

    {:ok, issue_9008} = Issues.capture_issue(system_scope(), project, "Task 9008")

    {:ok, %Task{id: _task_id} = task} = Pipeline.create_task(issue_9008, :product)

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 42,
        mergeability: :unknown,
        pr_is_draft: true
      })

    mock_installation_token_success(installation_id: 9006)
    mock_pull_request_state_success("testorg/testrepo", 42, mergeable: true, draft: false)

    assert {:ok, %Task{mergeability: :mergeable, pr_is_draft: false}} = Pipeline.refresh_mergeability(task)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :mergeability_refreshed}}
  end

  test "preserves conflicting status when GitHub returns unknown", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9009",
        github_repo: "testorg/testrepo",
        github_installation_id: 9009,
        linear_team_id: "team_refresh_merge_9009",
        linear_team_key: "P9009",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9009",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9010",
      "identifier" => "TSK-9010",
      "title" => "Task 9010"
    })

    {:ok, issue_9010} = Issues.capture_issue(system_scope(), project, "Task 9010")

    {:ok, task} = Pipeline.create_task(issue_9010, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 55,
        mergeability: :conflicting,
        pr_is_draft: false
      })

    mock_pull_request_state_success("testorg/testrepo", 55, mergeable: nil, draft: false)

    assert {:ok, %Task{mergeability: :conflicting, pr_is_draft: false}} =
             Pipeline.refresh_mergeability(task, token: "tok_test", attempts: 1, retry_delay_ms: 0)
  end

  test "preserves existing pr_is_draft when GitHub returns nil draft status", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9011",
        github_repo: "testorg/testrepo",
        github_installation_id: 9011,
        linear_team_id: "team_refresh_merge_9011",
        linear_team_key: "P9011",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9011",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9012",
      "identifier" => "TSK-9012",
      "title" => "Task 9012"
    })

    {:ok, issue_9012} = Issues.capture_issue(system_scope(), project, "Task 9012")

    {:ok, task} = Pipeline.create_task(issue_9012, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        pr_number: 66,
        mergeability: :unknown,
        pr_is_draft: true
      })

    mock_pull_request_state_success("testorg/testrepo", 66, mergeable: true, draft: nil)

    assert {:ok, %Task{mergeability: :mergeable, pr_is_draft: true}} =
             Pipeline.refresh_mergeability(task, token: "tok_test")
  end

  test "returns error when project is not found", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9013",
        github_repo: "org/refresh-merge-9013",
        github_installation_id: 9013,
        linear_team_id: "team_refresh_merge_9013",
        linear_team_key: "P9013",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9013",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9014",
      "identifier" => "TSK-9014",
      "title" => "Task 9014"
    })

    {:ok, issue_9014} = Issues.capture_issue(system_scope(), project, "Task 9014")

    {:ok, task} = Pipeline.create_task(issue_9014, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        pr_number: 99
      })

    Repo.delete!(project)

    assert {:error, :project_not_found} = Pipeline.refresh_mergeability(task)
  end

  test "returns error when token cannot be resolved", %{project: _project, task: _task} do
    mock_installation_token_error(401, "Bad credentials", installation_id: 12_345)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9015",
        github_repo: "org/refresh-merge-9015",
        github_installation_id: 12_345,
        linear_team_id: "team_refresh_merge_9015",
        linear_team_key: "P9015",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9015",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9016",
      "identifier" => "TSK-9016",
      "title" => "Task 9016"
    })

    {:ok, issue_9016} = Issues.capture_issue(system_scope(), project, "Task 9016")

    {:ok, task} = Pipeline.create_task(issue_9016, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        pr_number: 88
      })

    assert {:error, {:github_api_error, 401, _body}} = Pipeline.refresh_mergeability(task)
  end

  test "returns error when GitHub client returns error", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9017",
        github_repo: "testorg/testrepo",
        github_installation_id: 9017,
        linear_team_id: "team_refresh_merge_9017",
        linear_team_key: "P9017",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9017",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9018",
      "identifier" => "TSK-9018",
      "title" => "Task 9018"
    })

    {:ok, issue_9018} = Issues.capture_issue(system_scope(), project, "Task 9018")

    {:ok, task} = Pipeline.create_task(issue_9018, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        pr_number: 77
      })

    mock_pull_request_state_error("testorg/testrepo", 77, 404, "Not Found")

    assert {:error, {:github_api_error, 404, _body}} =
             Pipeline.refresh_mergeability(task, token: "tok_test")
  end

  test "checks demo staleness and re-queues ready_to_merge task when commit drifted", %{project: _project, task: _task} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Refresh Merge Project 9019",
        github_repo: "testorg/testrepo",
        github_installation_id: 9019,
        linear_team_id: "team_refresh_merge_9019",
        linear_team_key: "P9019",
        default_branch: "main",
        clone_path: "/tmp/repos/refresh-merge-9019",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    worktree = create_temp_git_repo()

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_refresh_merge_9020",
      "identifier" => "TSK-9020",
      "title" => "Task 9020"
    })

    {:ok, issue_9020} = Issues.capture_issue(system_scope(), project, "Task 9020")

    {:ok, task} = Pipeline.create_task(issue_9020, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :ready_to_merge,
        stage_state: :awaiting_approval,
        pr_number: 99,
        worktree_path: worktree
      })

    demo_scratch_9501 = Path.join("/tmp", "rail_demo_scratch_#{System.unique_integer([:positive])}")

    demo_scratch_dir_9501 = Path.join([demo_scratch_9501, "demo"])

    File.mkdir_p!(demo_scratch_dir_9501)

    on_exit(fn -> File.rm_rf(demo_scratch_9501) end)

    File.write!(Path.join(demo_scratch_dir_9501, "frame-1.png"), "fake demo frame")

    File.write!(
      Path.join(demo_scratch_dir_9501, "manifest.json"),
      Jason.encode!(%{
        "version" => 1,
        "outcome" => "recorded",
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Feature works",
            "outcome" => "recorded",
            "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
          }
        ]
      })
    )

    mock_demo_uploads(1)

    LinearMock.mock_create_comment_success(%{
      "id" => "cmt_demo_9501",
      "body" => "Demo",
      "createdAt" => "2026-09-05T12:00:00.000Z"
    })

    {:ok, _demo} =
      Artifacts.capture_demo(system_scope(), task, demo_scratch_9501, head_sha: "old_head_sha")

    mock_pull_request_state_success("testorg/testrepo", 99, mergeable: true, draft: false)

    assert {:ok, %Task{stage: :demo, stage_state: :queued, mergeability: :mergeable}} =
             Pipeline.refresh_mergeability(task, token: "tok_test")
  end
end
