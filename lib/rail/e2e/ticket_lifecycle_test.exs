defmodule Rail.E2E.TicketLifecycleTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.GitHub, as: GitHubMock
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    shim_dir = Path.expand("test/support/bin")
    old_path = System.get_env("PATH") || ""
    new_path = "#{shim_dir}:#{old_path}"
    System.put_env("PATH", new_path)

    system_scope = Rail.Scope.for_system()

    {:ok, claude_backend} =
      Rail.Backends.create_backend(system_scope, %{
        name: :claude,
        executable_path: Path.join(shim_dir, "claude")
      })

    {:ok, agy_backend} =
      Rail.Backends.create_backend(system_scope, %{
        name: :agy,
        executable_path: Path.join(shim_dir, "agy")
      })

    on_exit(fn ->
      System.put_env("PATH", old_path)
    end)

    repo_dir = create_temp_git_repo(initial_commit: true)

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "E2E Workspace 13603",
        external_id: "lin_ws_e2e_13603",
        token: "lin_ws_token_123",
        webhook_secret: "whsec_e2e_13603"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "E2E Project 13601",
        github_repo: "org/e2e-13601",
        github_installation_id: 13_601,
        linear_team_id: "team_test_101",
        linear_team_key: "ISS",
        clone_path: repo_dir,
        linear_state_ids: %{
          "triage" => "state_triage",
          "in_progress" => "state_in_progress",
          "done" => "state_done"
        },
        linear_workspace_id: workspace.id,
        default_branch: "main"
      })

    {:ok, user} =
      Rail.Users.register_oauth_user(%{
        github_id: "gh_e2e_101",
        login: "e2e_user",
        name: "E2E User",
        email: "e2e@example.com",
        github_token: "gho_e2e_token",
        admin: true
      })

    scope = %Rail.Scope{user: user, system: false}

    Enum.each([:product, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
      {:ok, _role} =
        Roles.create_role(system_scope(), project, %{
          stage: stage,
          name: "#{stage} role",
          backend_id: claude_backend.id,
          model: "claude-3-7-sonnet",
          system_prompt: "You are an expert agent for stage #{stage}."
        })
    end)

    scratch_dir = create_temp_git_repo()

    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    %{
      project: project,
      scope: scope,
      scratch_dir: scratch_dir,
      repo_dir: repo_dir,
      agy_backend: agy_backend
    }
  end

  test "complete ticket lifecycle from triage to merged with CLI shims", %{
    project: project,
    scope: scope,
    scratch_dir: scratch_dir
  } do
    # -------------------------------------------------------------------------
    # 1. Triage -> Captured Issue -> Task created (stage: :product, stage_state: :queued)
    # -------------------------------------------------------------------------
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_iss_101",
      "identifier" => "ISS-101",
      "title" => "Implement Feature End-to-End",
      "description" =>
        "Need feature end-to-end.\n\n## Acceptance criteria\n- Feature works end-to-end\n- Verification succeeds",
      "url" => "https://linear.app/issue/ISS-101",
      "state" => %{"name" => "Triage"},
      "branchName" => "feature-iss-101",
      "createdAt" => "2026-09-10T00:00:00Z",
      "updatedAt" => "2026-09-10T00:00:00Z"
    })

    assert {:ok, %Issue{id: issue_id, identifier: "ISS-101", state: :triage} = issue} =
             Rail.Issues.capture_issue(
               scope,
               project,
               "Implement Feature End-to-End\n\nNeed feature end-to-end.\n\n## Acceptance criteria\n- Feature works end-to-end\n- Verification succeeds"
             )

    assert {:ok, %Task{id: task_id, stage: :product, stage_state: :queued} = task} =
             Rail.Pipeline.create_task(issue, :product)

    # -------------------------------------------------------------------------
    # 2. Product run starts and settles -> parks for approval, which publishes the
    #    ticket and advances to :architect (no design role on this project)
    # -------------------------------------------------------------------------
    LinearMock.mock_update_issue_success(%{
      "id" => "lin_iss_101",
      "identifier" => "ISS-101",
      "title" => "Implement Feature End-to-End",
      "description" =>
        "The system needs end-to-end ticket lifecycle support with automated validation.\n\n## Acceptance Criteria\n- Feature works end-to-end\n- Verification succeeds",
      "url" => "https://linear.app/issue/ISS-101",
      "state" => %{"name" => "In Progress"},
      "updatedAt" => "2026-09-10T00:01:00Z"
    })

    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    task = Repo.get!(Task, task_id)
    assert %Task{stage: :product, stage_state: :awaiting_approval} = task

    assert {:ok, %{task: %Task{stage: :architect, stage_state: :queued} = task}} =
             Rail.Pipeline.approve_product_task(task, scratch_dir: scratch_dir, skip_follower: false)

    assert {:ok,
            %RoleRun{
              id: prod_role_run_id,
              status: :finished,
              exit_code: 0,
              usage: %Rail.Domain.TaskUsage{input_tokens: in_tok}
            }} = Rail.Runs.get_latest_role_run_for_task(task_id)

    assert in_tok > 0
    assert File.exists?(Path.join([scratch_dir, "tickets", "ISS-101.md"]))

    assert Repo.exists?(
             from(e in RunEvent,
               where: e.role_run_id == ^prod_role_run_id
             )
           )

    # -------------------------------------------------------------------------
    # 3. Architect run starts and settles -> captures plan.md, transitions to stage_state: :awaiting_approval
    # -------------------------------------------------------------------------
    LinearMock.mock_update_issue_success(%{
      "id" => "lin_iss_101",
      "identifier" => "ISS-101",
      "title" => "Implement Feature End-to-End",
      "description" =>
        "The system needs end-to-end ticket lifecycle support with automated validation.\n\n## Acceptance Criteria\n- Feature works end-to-end\n- Verification succeeds",
      "url" => "https://linear.app/issue/ISS-101",
      "state" => %{"name" => "In Progress"},
      "updatedAt" => "2026-09-10T00:02:00Z"
    })

    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    task = Repo.get!(Task, task_id)
    assert %Task{stage: :architect, stage_state: :awaiting_approval} = task

    assert {:ok, %RoleRun{status: :finished, exit_code: 0}} =
             Rail.Runs.get_latest_role_run_for_task(task_id)

    assert %Plan{content: "## Implementation plan" <> _rest} = Repo.get_by(Plan, task_id: task_id)

    # -------------------------------------------------------------------------
    # 4. Human approves plan -> advances to :engineer
    # -------------------------------------------------------------------------
    assert {:ok, %Task{stage: :engineer, stage_state: :queued} = task} =
             Rail.Pipeline.approve_stage(scope, task, scratch_dir: scratch_dir, skip_follower: false)

    # -------------------------------------------------------------------------
    # 5. Engineer run starts and settles -> touches worktree, commits, advances to :review
    # -------------------------------------------------------------------------
    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    assert %Task{stage: :review, stage_state: :queued, worktree_path: eng_wt_path} = task = Repo.get!(Task, task_id)

    assert {:ok, %RoleRun{status: :finished, exit_code: 0}} =
             Rail.Runs.get_latest_role_run_for_task(task_id)

    assert File.exists?(Path.join(eng_wt_path, "feature_work.txt"))

    {git_log, 0} = System.cmd("git", ["log", "-n", "1", "--oneline"], cd: eng_wt_path, env: %{})
    assert git_log =~ "feat: engineer implementation pass"

    # -------------------------------------------------------------------------
    # 6. Reviewer run starts and settles -> parses VERDICT: PASSED, advances to :qa
    # -------------------------------------------------------------------------
    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    task = Repo.get!(Task, task_id)
    assert %Task{stage: :qa, stage_state: :queued} = task

    assert {:ok, %RoleRun{status: :finished, exit_code: 0, output: rev_out}} =
             Rail.Runs.get_latest_role_run_for_task(task_id)

    assert rev_out =~ "VERDICT: PASSED"

    # -------------------------------------------------------------------------
    # 7. QA run starts and settles -> captures QA report into Postgres, parses VERDICT: PASSED, advances to :qa_lead
    # -------------------------------------------------------------------------
    LinearMock.mock_create_comment_success(%{
      "id" => "cmnt_qa_101",
      "body" => "QA Report"
    })

    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    task = Repo.get!(Task, task_id)
    assert %Task{stage: :qa_lead, stage_state: :queued} = task

    assert {:ok, %RoleRun{status: :finished, exit_code: 0, output: qa_out}} =
             Rail.Runs.get_latest_role_run_for_task(task_id)

    assert qa_out =~ "VERDICT: PASSED"
    assert %QaReport{rows: [_row]} = Repo.get_by(QaReport, task_id: task_id)

    # -------------------------------------------------------------------------
    # 8. QA Lead run starts and settles -> parses VERDICT: PASSED, advances to :demo
    # -------------------------------------------------------------------------
    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    task = Repo.get!(Task, task_id)
    assert %Task{stage: :demo, stage_state: :queued} = task

    assert {:ok, %RoleRun{status: :finished, exit_code: 0, output: lead_out}} =
             Rail.Runs.get_latest_role_run_for_task(task_id)

    assert lead_out =~ "VERDICT: PASSED"

    # -------------------------------------------------------------------------
    # 9. Demo run starts and settles -> captures demo into Postgres, advances to :ready_to_merge
    # -------------------------------------------------------------------------
    LinearMock.mock_file_upload_success(
      upload_url: "https://api.linear.app/upload/dmo_101",
      asset_url: "https://uploads.linear.app/dmo_101/frame-1.png",
      asset_id: "ast_dmo_101"
    )

    LinearMock.mock_create_comment_success(%{
      "id" => "cmnt_demo_101",
      "body" => "Demo recorded"
    })

    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    assert %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, worktree_path: worktree_path_before_merge} =
             task = Repo.get!(Task, task_id)

    assert {:ok, %RoleRun{status: :finished, exit_code: 0}} =
             Rail.Runs.get_latest_role_run_for_task(task_id)

    assert %Demo{outcome: "recorded", segments: [_seg1, _seg2]} = Repo.get_by(Demo, task_id: task_id)

    # -------------------------------------------------------------------------
    # 10. Human merges task -> squash merges PR, deletes branch, releases worktree, marks Done, updates stage: :merged
    # -------------------------------------------------------------------------
    {:ok, task} =
      task
      |> Task.changeset(%{
        pr_number: 101,
        pr_url: "https://github.com/example/repo-test/pull/101",
        pr_is_draft: false
      })
      |> Repo.update()

    GitHubMock.mock_merge_pull_request_success(project.github_repo, 101,
      user_token: "gho_e2e_token",
      merge_method: "squash"
    )

    GitHubMock.mock_delete_remote_branch_success(project.github_repo, task.worktree_name, user_token: "gho_e2e_token")

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_iss_101",
      "identifier" => "ISS-101",
      "title" => "Implement Feature End-to-End",
      "state" => %{"name" => "Done"}
    })

    assert {:ok, %Task{stage: :merged, merged_at: %DateTime{}}} =
             Rail.Pipeline.merge_task(scope, task)

    assert %Issue{state: :done} = Repo.get!(Issue, issue_id)
    refute File.dir?(worktree_path_before_merge)
  end

  test "executes stage runs with agy CLI backend shim", %{
    project: project,
    scope: scope,
    scratch_dir: scratch_dir,
    agy_backend: agy_backend
  } do
    {:ok, agy_project} =
      Projects.create_project(system_scope(), %{
        name: "E2E Project 13602",
        github_repo: "org/e2e-13602",
        github_installation_id: 13_602,
        linear_team_id: "team_agy_102",
        linear_team_key: "AGY",
        clone_path: project.clone_path,
        linear_state_ids: %{
          "triage" => "state_triage",
          "in_progress" => "state_in_progress",
          "done" => "state_done"
        },
        linear_workspace_id: project.linear_workspace_id,
        default_branch: "main"
      })

    Enum.each([:product, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
      {:ok, _role} =
        Roles.create_role(system_scope(), agy_project, %{
          stage: stage,
          name: "#{stage} role",
          backend_id: agy_backend.id,
          model: "claude-3-7-sonnet",
          system_prompt: "You are an expert agent for stage #{stage}."
        })
    end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_iss_102",
      "identifier" => "AGY-102",
      "title" => "Agy Feature",
      "description" => "Description for agy feature\n\n## Acceptance criteria\n- Works with agy",
      "url" => "https://linear.app/issue/AGY-102",
      "state" => %{"name" => "Triage"},
      "branchName" => "feature-agy-102"
    })

    assert {:ok, issue} =
             Rail.Issues.capture_issue(
               scope,
               agy_project,
               "Agy Feature\n\nDescription for agy feature\n\n## Acceptance criteria\n- Works with agy"
             )

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_iss_102",
      "identifier" => "AGY-102",
      "title" => "Agy Feature",
      "description" => "Description for agy feature\n\n## Acceptance criteria\n- Works with agy",
      "url" => "https://linear.app/issue/AGY-102",
      "state" => %{"name" => "In Progress"},
      "branchName" => "feature-agy-102"
    })

    assert {:ok, %Task{id: task_id, stage: :product, stage_state: :queued} = task} =
             Rail.Pipeline.create_task(issue, :product)

    LinearMock.mock_update_issue_success(%{
      "id" => "lin_iss_102",
      "identifier" => "AGY-102",
      "title" => "Implement Feature End-to-End",
      "description" =>
        "The system needs end-to-end ticket lifecycle support with automated validation.\n\n## Acceptance Criteria\n- Feature works end-to-end\n- Verification succeeds",
      "url" => "https://linear.app/issue/AGY-102",
      "state" => %{"name" => "In Progress"}
    })

    {:ok, _dispatched} = Rail.Pipeline.start_stage_run(task, scratch_dir: scratch_dir, skip_follower: false)
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}, 10_000

    task = Repo.get!(Task, task_id)
    assert %Task{stage: :product, stage_state: :awaiting_approval} = task

    assert {:ok, %{task: %Task{stage: :architect, stage_state: :queued}}} =
             Rail.Pipeline.approve_product_task(task, scratch_dir: scratch_dir, skip_follower: false)

    assert {:ok, %RoleRun{status: :finished, exit_code: 0}} = Rail.Runs.get_latest_role_run_for_task(task_id)
  end
end
