defmodule Rail.Pipeline.Actions.SettleRunTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CaptureScratch
  import Rail.Pipeline.Utils.PrepareScratch
  import RailTest.Mocks.GitHub
  import RailTest.PipelineHelpers

  alias Rail.Artifacts
  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.TaskUsage
  alias Rail.Git
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Run Workspace",
        external_id: "lin_ws_settle_run",
        token: "lin_api_token_settle_run",
        webhook_secret: "whsec_settle_run"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Run Project 14501",
        github_repo: "org/settle-run-14501",
        github_installation_id: 14_501,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_run_14501",
        linear_team_key: "P14501",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-run-14501",
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
      "id" => "lin_settle_run_1",
      "identifier" => "STR-1",
      "title" => "Settle Run Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Run Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(scope, task.id, %{issue_id: nil})

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "returns not_found when task cannot be resolved", %{task: task, roles: roles} do
    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, :not_found} =
             Pipeline.settle_run("tsk_000000000000000000000000", role_run_id)
  end

  test "returns not_found when role_run cannot be resolved", %{task: %Task{id: task_id}} do
    assert {:error, :not_found} =
             Pipeline.settle_run(task_id, "rr_000000000000000000000000")
  end

  test "settles clean exit 0 for product stage by parking at awaiting_approval", %{task: task, roles: roles} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    _product_role = roles[:product]

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :product,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{id: ^task_id, stage: :product, stage_state: :awaiting_approval},
            %RoleRun{status: :finished, exit_code: 0, auto_retries: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :run_settled}}
  end

  test "settling the product stage writes nothing to Linear", %{task: task, issue: issue, roles: roles} do
    scratch_dir = Path.join(System.tmp_dir!(), "settle_product_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch_dir, "tickets"))
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    title_before = issue.title
    ticket_file = Path.join([scratch_dir, "tickets", "#{issue.identifier}.md"])
    File.write!(ticket_file, "---\ntitle: Rewritten by the product run\n---\n\nA body the human has not approved.\n")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        stage: :product,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:product].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    # No Linear mock is set up: a push would raise on the unexpected request.
    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0}, scratch_dir: scratch_dir)

    assert %Issue{title: ^title_before} = Repo.get!(Issue, issue.id)
  end

  test "settles clean exit 0 for architect stage advancing to awaiting_approval when plan exists", %{
    task: task,
    roles: roles
  } do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :running
      })

    # settle_run captures the plan again, so keep the plan on the real filesystem.
    plan_dir = Path.join("/tmp", "rail_plan_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plan_dir)
    File.write!(Path.join(plan_dir, "plan.md"), "# Architecture Plan")
    on_exit(fn -> File.rm_rf(plan_dir) end)

    {:ok, _captured} = capture_scratch(:architect, task, plan_dir)

    {:ok, _plan} = Pipeline.get_plan(system_scope(), task_id)

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval, retry_after: nil, error: nil},
            %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "settles clean exit 0 for architect stage failing when plan file was not written", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, error: error_msg}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})

    assert error_msg =~ "without writing a plan"
  end

  test "settles clean exit 0 for engineer stage advancing to review", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{id: ^task_id, stage: :review, stage_state: :queued}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "settles clean exit 0 for rebasing task restoring previous stage state", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok,
            %Task{
              id: ^task_id,
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil
            }, %RoleRun{status: :finished, exit_code: 0, auto_retries: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "settles clean exit 0 for generic stage setting awaiting_approval", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval}, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0})
  end

  test "handles transient failure with retry backoff when auto retries remain", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 0
      })

    transient_err = "rate limit exceeded: 429 too many requests"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :queued,
              retry_after: %DateTime{},
              error: ^transient_err
            }, %RoleRun{status: :finished, auto_retries: 1, exit_code: 1}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: transient_err})
  end

  test "handles transient failure marking failed when max auto retries are exhausted", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 2
      })

    transient_err = "rate limit exceeded: 429 too many requests"

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, retry_after: nil, error: ^transient_err},
            %RoleRun{status: :finished, auto_retries: 2, exit_code: 1}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: transient_err})
  end

  test "handles permanent failure immediately marking task and role run as failed", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 0
      })

    perm_err = "fatal syntax error: unexpected token"

    assert {:ok, %Task{id: ^task_id, stage_state: :failed, error: ^perm_err},
            %RoleRun{status: :finished, auto_retries: 0, exit_code: 1}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: perm_err})
  end

  test "resolves string keys, updates associated Run, and captures scratch artifacts", %{task: task, roles: roles} do
    scratch_dir = create_temp_git_repo()

    {:ok, %Task{id: task_id}} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :architect,
        stage_state: :running
      })

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, %Run{id: run_id} = run} =
      Runs.start_run(role_run_id, :stage, ["/bin/sleep", "5"], skip_follower: true)

    plan_path = Path.join(scratch_dir, "plan.md")
    File.write!(plan_path, "# Captured Architecture Plan")

    outcome = %{
      "exit_code" => 0,
      "output" => "Run finished cleanly",
      "usage" => %{"input_tokens" => 500, "output_tokens" => 150},
      :run => run
    }

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval},
            %RoleRun{id: ^role_run_id, status: :finished, output: "Run finished cleanly"}} =
             Pipeline.settle_run(task_id, role_run_id, outcome, scratch_dir: scratch_dir)

    assert %Run{id: ^run_id, status: :finished} = Repo.get!(Run, run_id)
    assert %Plan{content: plan_content} = Repo.one(from p in Plan, where: p.task_id == ^task_id)
    assert plan_content =~ "Captured Architecture Plan"
  end

  test "resolves exit code, output, error, and usage fallbacks from role_run or defaults", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        exit_code: 0,
        output: "prior output",
        error: nil
      })

    assert {:ok, %Task{id: ^task_id, stage_state: :awaiting_approval}, %RoleRun{output: "prior output"}} =
             Pipeline.settle_run(task, role_run, %{})
  end

  test "maybe_finish_run updates run when passed as top-level run struct", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, %Run{id: run_id} = run} =
      Runs.start_run(role_run.id, :stage, ["/bin/sleep", "5"], skip_follower: true)

    assert {:ok, _task, _role_run} = Pipeline.settle_run(task, role_run, run)
    assert %Run{id: ^run_id, status: :finished} = Repo.get!(Run, run_id)
  end

  test "returns not_found when targets are invalid types", %{task: task, roles: roles} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:error, :not_found} = Pipeline.settle_run(12_345, role_run)
    assert {:error, :not_found} = Pipeline.settle_run(task, 12_345)
  end

  test "resolves fallback exit code, string error, and prior role_run error", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        exit_code: nil,
        error: nil
      })

    assert {:ok, _t1, %RoleRun{exit_code: 0}} = Pipeline.settle_run(task, role_run, %{})

    assert {:ok, _t2, %RoleRun{error: "string err"}} =
             Pipeline.settle_run(task, role_run, %{"error" => "string err", "exit_code" => 1})

    {:ok, role_run_err} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        exit_code: 1,
        error: "prior err"
      })

    assert {:ok, _t3, %RoleRun{error: "prior err"}} =
             Pipeline.settle_run(task, role_run_err, %{"exit_code" => 1})
  end

  test "resolves atom-keyed output and various usage input formats", %{task: task, roles: roles} do
    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :design,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, _t1, %RoleRun{output: "atom output"}} =
             Pipeline.settle_run(task, role_run, %{output: "atom output"})

    usage_struct = %TaskUsage{input_tokens: 42, output_tokens: 10}

    assert {:ok, _t2, %RoleRun{usage: %TaskUsage{input_tokens: 42}}} =
             Pipeline.settle_run(task, role_run, %{usage: usage_struct})

    assert {:ok, _t3, %RoleRun{usage: %TaskUsage{input_tokens: 55}}} =
             Pipeline.settle_run(task, role_run, %{usage: %{"input_tokens" => 55}})

    assert {:ok, _t4, %RoleRun{usage: %TaskUsage{input_tokens: 42}}} =
             Pipeline.settle_run(task, role_run, %{"usage" => usage_struct})
  end

  test "settles clean exit 0 for review stage with passed verdict advancing to qa", %{task: task, roles: roles} do
    {:ok, %Role{id: role_rev_id} = role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, _role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA"
      })

    git_repo = create_temp_git_repo()

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        worktree_path: git_repo
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Code looks great!\n\nVERDICT: APPROVED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :queued,
              outstanding_reports: [^role_rev_id]
            },
            %RoleRun{
              status: :finished,
              exit_code: 0,
              stage_fingerprint_head_sha: head_sha,
              stage_fingerprint_dirty_digest: dirty_digest
            }} = Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert is_binary(head_sha) and head_sha != ""
    assert is_binary(dirty_digest) and dirty_digest != ""
  end

  test "settles clean exit 0 for qa stage with passed verdict advancing to qa_lead", %{task: task, roles: roles} do
    {:ok, %Role{id: role_qa_id} = role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    {:ok, _role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Test checklist passed.\n\nVERDICT: PASS"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa_lead,
              stage_state: :queued,
              outstanding_reports: [^role_qa_id]
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settles clean exit 0 for qa stage with valid manifest capturing report and advancing to qa_lead", %{
    project: project,
    issue: _issue,
    task: task,
    roles: roles
  } do
    {:ok, _ws} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Run Workspace 14600",
        external_id: "lin_ws_settle_run_14600",
        token: "lin_api_token_settle_run_14600",
        webhook_secret: "whsec_settle_run_14600"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_qa_settle",
      "identifier" => "ISS-14598",
      "title" => "Settle Run Issue 14598"
    })

    {:ok, issue} = Issues.capture_issue(system_scope(), project, "Settle Run Issue 14598")

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_settle_run_14617",
        login: "settle_run_user_14617",
        email: "settle_run_user_14617@example.com",
        github_token: "gho_token_14617"
      })

    {:ok, %Role{id: role_qa_id} = role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    {:ok, _role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    scratch_dir = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([scratch_dir | List.wrap(["qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "abc1234",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{
                "name" => "screenshot.png",
                "kind" => "image",
                "path" => "screenshot.png"
              }
            ]
          }
        ]
      })
    )

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        issue_id: issue.id,
        owner_user_id: user.id,
        stage: :qa,
        stage_state: :running
      })

    {:ok, %RoleRun{id: role_run_id} = role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    mock_qa_uploads(1)
    LinearMock.mock_create_comment_success(%{"id" => "cmt_qa_settle", "body" => "QA comment"})

    output = "QA checklist completed.\n\nVERDICT: PASS"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa_lead,
              stage_state: :queued,
              outstanding_reports: [^role_qa_id]
            }, %RoleRun{status: :finished, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output}, scratch_dir: scratch_dir)

    assert %QaReport{
             task_id: ^task_id,
             role_run_id: ^role_run_id,
             commit: "abc1234",
             rows: [
               %{
                 artifacts: [
                   %{url: "https://uploads.linear.app/qa_1/screenshot-1.png"}
                 ]
               }
             ]
           } = Repo.one(from q in QaReport, where: q.task_id == ^task_id)
  end

  test "settles clean exit 0 for qa stage with invalid manifest sets stage_state to failed", %{task: task, roles: roles} do
    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    scratch_dir = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([scratch_dir | List.wrap(["qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(Path.join(qa_dir, "manifest.json"), "{broken_json")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: err_msg
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_dir: scratch_dir)

    assert err_msg =~ "Failed to parse QA manifest"
  end

  test "settles clean exit 0 for qa stage with missing manifest and require_qa_manifest: true fails stage", %{
    task: task,
    roles: roles
  } do
    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    scratch_dir = create_temp_git_repo()

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: "QA manifest not found."
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "VERDICT: PASS"},
               scratch_dir: scratch_dir,
               require_qa_manifest: true
             )
  end

  test "settles clean exit 0 for qa stage resolving manifest from worktree .rail/qa, worktree qa, and root", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    {:ok, _role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    # Case A: Worktree with .rail/qa
    worktree_rail = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([worktree_rail | List.wrap([".rail", "qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(worktree_rail) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "rail_sha",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{"name" => "log.txt", "kind" => "text", "path" => "log.txt", "text" => "All checks passed"}
            ]
          }
        ]
      })
    )

    {:ok, task_rail} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running,
        worktree_path: worktree_rail
      })

    {:ok, role_run_rail} =
      Runs.create_role_run(%{
        task_id: task_rail.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_rail, role_run_rail, %{exit_code: 0, output: "VERDICT: PASS"})

    assert %QaReport{commit: "rail_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_rail.id)

    # Case B: Worktree with qa/
    worktree_qa = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([worktree_qa | List.wrap(["qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(worktree_qa) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "wt_qa_sha",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{"name" => "log.txt", "kind" => "text", "path" => "log.txt", "text" => "All checks passed"}
            ]
          }
        ]
      })
    )

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14502",
      "identifier" => "TSK-14502",
      "title" => "Task 14502"
    })

    {:ok, issue_14502} = Issues.capture_issue(system_scope(), project, "Task 14502")

    {:ok, task_qa} = Pipeline.create_task(issue_14502, :product)

    {:ok, task_qa} = Pipeline.update_task(system_scope(), task_qa.id, %{issue_id: nil})

    {:ok, task_qa} =
      Pipeline.update_task(system_scope(), task_qa.id, %{
        stage: :qa,
        stage_state: :running,
        worktree_path: worktree_qa
      })

    {:ok, role_run_qa} =
      Runs.create_role_run(%{
        task_id: task_qa.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_qa, role_run_qa, %{exit_code: 0, output: "VERDICT: PASS"})

    assert %QaReport{commit: "wt_qa_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_qa.id)

    # Case C: Scratch with manifest in root
    scratch_root = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([scratch_root | List.wrap([])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_root) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "root_sha",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{"name" => "log.txt", "kind" => "text", "path" => "log.txt", "text" => "All checks passed"}
            ]
          }
        ]
      })
    )

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14503",
      "identifier" => "TSK-14503",
      "title" => "Task 14503"
    })

    {:ok, issue_14503} = Issues.capture_issue(system_scope(), project, "Task 14503")

    {:ok, task_root} = Pipeline.create_task(issue_14503, :product)

    {:ok, task_root} = Pipeline.update_task(system_scope(), task_root.id, %{issue_id: nil})

    {:ok, task_root} =
      Pipeline.update_task(system_scope(), task_root.id, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, role_run_root} =
      Runs.create_role_run(%{
        task_id: task_root.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_root, role_run_root, %{exit_code: 0, output: "VERDICT: PASS"},
               scratch_dir: scratch_root
             )

    assert %QaReport{commit: "root_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_root.id)

    # Case D: Worktree with manifest in root
    worktree_root = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([worktree_root | List.wrap([])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(worktree_root) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "wt_root_sha",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{"name" => "log.txt", "kind" => "text", "path" => "log.txt", "text" => "All checks passed"}
            ]
          }
        ]
      })
    )

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14504",
      "identifier" => "TSK-14504",
      "title" => "Task 14504"
    })

    {:ok, issue_14504} = Issues.capture_issue(system_scope(), project, "Task 14504")

    {:ok, task_wt_root} = Pipeline.create_task(issue_14504, :product)

    {:ok, task_wt_root} = Pipeline.update_task(system_scope(), task_wt_root.id, %{issue_id: nil})

    {:ok, task_wt_root} =
      Pipeline.update_task(system_scope(), task_wt_root.id, %{
        stage: :qa,
        stage_state: :running,
        worktree_path: worktree_root
      })

    {:ok, role_run_wt_root} =
      Runs.create_role_run(%{
        task_id: task_wt_root.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_wt_root, role_run_wt_root, %{exit_code: 0, output: "VERDICT: PASS"})

    assert %QaReport{commit: "wt_root_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_wt_root.id)

    # Case E: scratch_path option pointing directly to manifest or subfolder
    scratch_p = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([scratch_p | List.wrap(["qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_p) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "scratch_p_sha",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{"name" => "log.txt", "kind" => "text", "path" => "log.txt", "text" => "All checks passed"}
            ]
          }
        ]
      })
    )

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14505",
      "identifier" => "TSK-14505",
      "title" => "Task 14505"
    })

    {:ok, issue_14505} = Issues.capture_issue(system_scope(), project, "Task 14505")

    {:ok, task_p} = Pipeline.create_task(issue_14505, :product)

    {:ok, task_p} = Pipeline.update_task(system_scope(), task_p.id, %{issue_id: nil})

    {:ok, task_p} =
      Pipeline.update_task(system_scope(), task_p.id, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, role_run_p} =
      Runs.create_role_run(%{
        task_id: task_p.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :qa_lead}, %RoleRun{}} =
             Pipeline.settle_run(task_p, role_run_p, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_path: scratch_p)

    assert %QaReport{commit: "scratch_p_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task_p.id)
  end

  test "settles clean exit 0 for qa stage with VERDICT: FAIL captures QA report and routes to engineer", %{
    task: task,
    roles: roles
  } do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    scratch_dir = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([scratch_dir | List.wrap(["qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "fail_qa_commit",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "caused_by_change" => true,
            "command" => "mix test",
            "exit_code" => 0,
            "note" => "Passed cleanly",
            "artifacts" => [
              %{"name" => "log.txt", "kind" => "text", "path" => "log.txt", "text" => "All checks passed"}
            ]
          }
        ]
      })
    )

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running,
        rework_cycles: 0,
        rework_cycles_by_gate: %{}
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _prior_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_eng",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output = "Button is broken.\n\nVERDICT: FAIL"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :engineer,
              stage_state: :queued,
              rework_cycles: 1
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output}, scratch_dir: scratch_dir)

    assert %QaReport{commit: "fail_qa_commit"} = Repo.one(from q in QaReport, where: q.task_id == ^task_id)

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Button is broken."
  end

  test "settles clean exit 0 for qa stage fails task when artifact capture fails", %{task: task, roles: roles} do
    {:ok, _ws} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Run Workspace 14601",
        external_id: "lin_ws_settle_run_14601",
        token: "lin_api_token_settle_run_14601",
        webhook_secret: "whsec_settle_run_14601"
      })

    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    scratch_dir = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([scratch_dir | List.wrap(["qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "abc1234",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "check_1",
            "check" => "Login works",
            "result" => "pass",
            "severity" => "blocker",
            "artifacts" => [
              %{
                "name" => "screenshot.png",
                "kind" => "image",
                "path" => "screenshot.png"
              }
            ]
          }
        ]
      })
    )

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Plug.Conn.send_resp(conn, 500, "Upload error")
    end)

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: err_msg
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_dir: scratch_dir)

    assert err_msg =~ "linear_api_error"
  end

  test "end-to-end pipeline flow: QA -> QA Lead materialization -> Ready to merge", %{task: task, roles: roles} do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:demo])

    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    {:ok, role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    qa_scratch_dir = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join([qa_scratch_dir | List.wrap(["qa"])])
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(qa_scratch_dir) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "flow_commit",
        "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
        "rows" => [
          %{
            "id" => "flow_1",
            "check" => "Flow check",
            "result" => "pass",
            "severity" => "cosmetic",
            "artifacts" => [%{"name" => "proof.txt", "kind" => "text", "text" => "FLOW PROOF TEXT"}]
          }
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, role_run_qa} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    # Step 1: Settle QA run
    assert {:ok, %Task{stage: :qa_lead, stage_state: :queued} = task_lead_queued, _rr} =
             Pipeline.settle_run(task, role_run_qa, %{exit_code: 0, output: "VERDICT: PASS"}, scratch_dir: qa_scratch_dir)

    # Step 2: Scratch prepare for QA Lead
    lead_scratch_dir = create_temp_git_repo()
    assert {:ok, ^lead_scratch_dir} = prepare_scratch(task_lead_queued, lead_scratch_dir)

    # Verify materialization into lead scratch dir
    assert File.exists?(Path.join([lead_scratch_dir, "qa", "manifest.json"]))
    assert File.read!(Path.join([lead_scratch_dir, "qa", "proof.txt"])) == "FLOW PROOF TEXT"

    # Step 3: Settle QA Lead run
    {:ok, role_run_lead} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, _rr2} =
             Pipeline.settle_run(task_lead_queued, role_run_lead, %{exit_code: 0, output: "VERDICT: PASS"},
               scratch_dir: lead_scratch_dir
             )
  end

  test "settles clean exit 0 for qa_lead stage with passed verdict advancing to demo if configured", %{
    task: task,
    roles: roles
  } do
    {:ok, role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    {:ok, _role_demo} =
      Roles.update_role(system_scope(), roles[:demo], %{
        name: "Demo Recorder"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA Lead evaluation successful.\n\nVERDICT: PASSED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :demo,
              stage_state: :queued
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settles clean exit 0 for qa_lead stage with passed verdict advancing to ready_to_merge if no demo role", %{
    task: task,
    roles: roles
  } do
    {:ok, _deleted} = Roles.delete_role(system_scope(), roles[:demo])

    {:ok, role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa_lead,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA Lead evaluation successful.\n\nVERDICT: APPROVED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :ready_to_merge,
              stage_state: :awaiting_approval
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settles gate with changes_requested within budget routing back to engineer with carried reports", %{
    task: task,
    roles: roles
  } do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    {:ok, %Role{id: role_rev_id} = role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, role_prior} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "Prior QA"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{},
        outstanding_reports: [role_prior.id]
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_prior.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now(),
        output: "Prior QA note: button is off-center."
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _eng_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_eng",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output = "Please fix test coverage.\n\nVERDICT: CHANGES REQUESTED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :engineer,
              stage_state: :queued,
              rework_cycles: 1,
              rework_cycles_by_gate: %{^role_rev_id => 1},
              outstanding_reports: []
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    engineer_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert engineer_run.pending_answer =~ "Findings from Reviewer on the change you just pushed (rework 1 of 5)"
    assert engineer_run.pending_answer =~ "Please fix test coverage."
    assert engineer_run.pending_answer =~ "Also outstanding: what the other gates last reported"
    assert engineer_run.pending_answer =~ "### Prior QA\n\nPrior QA note: button is off-center."
  end

  test "settles gate with changes_requested parking for human when per-gate rework limit is reached", %{
    task: task,
    roles: roles
  } do
    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 3,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{role_rev.id => 3}
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Still not fixed.\n\nVERDICT: FAIL"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :review,
              stage_state: :awaiting_approval,
              rework_cycles: 3,
              error: err
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert err =~ "Reviewer is still requesting changes after 3 rework cycles."
    assert err =~ "Send back to Engineer to have them addressed, or Skip"
  end

  test "settles gate with changes_requested parking for human when global rework ceiling is reached", %{
    task: task,
    roles: roles
  } do
    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running,
        rework_cycles: 5,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{"other_gate" => 2, role_qa.id => 1}
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA failure.\n\nVERDICT: FAILED"

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :awaiting_approval,
              rework_cycles: 5,
              error: err
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert err =~ "QA Tester is still requesting changes after 1 rework cycle."
  end

  test "settles gate with unclear verdict parking for human", %{task: task, roles: roles} do
    {:ok, %Role{id: role_rev_id} = role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Here are some notes but no verdict keyword."

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :awaiting_approval,
              error: err,
              outstanding_reports: [^role_rev_id]
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert err =~ "Reviewer ended without a clear verdict. Read its report, then Send back to Engineer or Skip"
  end

  test "settles gate pass with rework stamping evidence commit line to next stage pending_answer", %{
    task: task,
    roles: roles
  } do
    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    git_repo = create_temp_git_repo()

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _qa_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_qa",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output = "Rework resolved nicely.\n\nVERDICT: APPROVED"

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %RoleRun{stage_fingerprint_head_sha: head_sha}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    qa_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_qa.id)
    assert qa_run.pending_answer =~ "The change has been reworked and the reviewer has signed off on it again."
    assert qa_run.pending_answer =~ "The reworked change is commit #{head_sha}."
  end

  test "skips the evidence line when the next stage has never held a conversation", %{
    task: task,
    roles: roles
  } do
    {:ok, role_rev} = Roles.update_role(system_scope(), roles[:review], %{name: "Reviewer"})
    {:ok, role_qa} = Roles.update_role(system_scope(), roles[:qa], %{name: "QA Tester"})

    git_repo = create_temp_git_repo()

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Rework resolved nicely.\n\nVERDICT: APPROVED"

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %RoleRun{}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_qa.id) == nil
  end

  test "settles gate with changes_requested appending to existing engineer pending_answer or missing engineer role", %{
    task: task,
    roles: roles
  } do
    {:ok, role_eng} =
      Roles.update_role(system_scope(), roles[:engineer], %{
        name: "Engineer"
      })

    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now(),
        pending_answer: "Old engineer notes"
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Please fix tests.\n\nVERDICT: CHANGES REQUESTED"

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    eng_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
    assert eng_run.pending_answer =~ "Old engineer notes\n\nFindings from Reviewer"

    # Part B: Project without engineer role
    {:ok, project_no_eng} =
      Projects.create_project(system_scope(), %{
        name: "Settle Run Project 14512",
        github_repo: "org/settle-run-14512",
        github_installation_id: 14_512,
        linear_team_id: "team_settle_run_14512",
        linear_team_key: "P14512",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-run-14512",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role_rev2} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer 2"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14506",
      "identifier" => "TSK-14506",
      "title" => "Task 14506"
    })

    {:ok, issue_14506} = Issues.capture_issue(system_scope(), project_no_eng, "Task 14506")

    {:ok, %Task{id: _task_id2} = task2} = Pipeline.create_task(issue_14506, :product)

    {:ok, task2} = Pipeline.update_task(system_scope(), task2.id, %{issue_id: nil})

    {:ok, %Task{id: task_id2} = task2} =
      Pipeline.update_task(system_scope(), task2.id, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0
      })

    {:ok, role_run2} =
      Runs.create_role_run(%{
        task_id: task_id2,
        role_id: role_rev2.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task2, role_run2, %{exit_code: 0, output: output})
  end

  test "settles gate pass with rework from qa and qa_lead appending to existing pending_answer or missing next role", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    {:ok, role_lead} =
      Roles.update_role(system_scope(), roles[:qa_lead], %{
        name: "QA Lead"
      })

    git_repo = create_temp_git_repo()

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :qa,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now(),
        pending_answer: "Prior lead notes"
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA passed cleanly.\n\nVERDICT: PASS"

    assert {:ok, %Task{stage: :qa_lead, stage_state: :queued}, %RoleRun{stage_fingerprint_head_sha: head_sha}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    lead_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_lead.id)

    assert lead_run.pending_answer =~
             "Prior lead notes\n\nThe change has been reworked and QA has signed off on it again."

    assert lead_run.pending_answer =~ "The reworked change is commit #{head_sha}."

    # Part B: QA lead pass with rework when project HAS a demo role (hits "the previous gate" label)
    {:ok, role_demo} =
      Roles.update_role(system_scope(), roles[:demo], %{
        name: "Demo Recorder"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14507",
      "identifier" => "TSK-14507",
      "title" => "Task 14507"
    })

    {:ok, issue_14507} = Issues.capture_issue(system_scope(), project, "Task 14507")

    {:ok, %Task{id: _task_id2} = task2} = Pipeline.create_task(issue_14507, :product)

    {:ok, task2} = Pipeline.update_task(system_scope(), task2.id, %{issue_id: nil})

    {:ok, %Task{id: task_id2} = task2} =
      Pipeline.update_task(system_scope(), task2.id, %{
        stage: :qa_lead,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, role_run2} =
      Runs.create_role_run(%{
        task_id: task_id2,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _demo_run} =
      Runs.create_role_run(%{
        task_id: task_id2,
        role_id: role_demo.id,
        conversation_id: "sess_demo",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output2 = "QA Lead pass.\n\nVERDICT: PASS"

    assert {:ok, %Task{stage: :demo, stage_state: :queued}, %RoleRun{stage_fingerprint_head_sha: head_sha2}} =
             Pipeline.settle_run(task2, role_run2, %{exit_code: 0, output: output2})

    demo_run = Repo.one(from r in RoleRun, where: r.task_id == ^task_id2 and r.role_id == ^role_demo.id)
    assert demo_run.pending_answer =~ "The change has been reworked and the previous gate has signed off on it again."
    assert demo_run.pending_answer =~ "The reworked change is commit #{head_sha2}."

    # Part C: Review stage pass with rework when next stage (:qa) role does NOT exist
    {:ok, project_no_qa} =
      Projects.create_project(system_scope(), %{
        name: "Settle Run Project 14513",
        github_repo: "org/settle-run-14513",
        github_installation_id: 14_513,
        linear_team_id: "team_settle_run_14513",
        linear_team_key: "P14513",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-run-14513",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, role_rev3} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer 3"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14508",
      "identifier" => "TSK-14508",
      "title" => "Task 14508"
    })

    {:ok, issue_14508} = Issues.capture_issue(system_scope(), project_no_qa, "Task 14508")

    {:ok, %Task{id: _task_id3} = task3} = Pipeline.create_task(issue_14508, :product)

    {:ok, task3} = Pipeline.update_task(system_scope(), task3.id, %{issue_id: nil})

    {:ok, %Task{id: task_id3} = task3} =
      Pipeline.update_task(system_scope(), task3.id, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, role_run3} =
      Runs.create_role_run(%{
        task_id: task_id3,
        role_id: role_rev3.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task3, role_run3, %{exit_code: 0, output: "VERDICT: APPROVED"})

    # Part D: Gate unclear with unknown role ID falls back to to_string(role_id)
    unknown_role_id = "rol_unknown_gate"

    {:ok, role_run_unknown} =
      Runs.create_role_run(%{
        task_id: task_id3,
        role_id: unknown_role_id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage_state: :awaiting_approval, error: err}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task3, role_run_unknown, %{exit_code: 0, output: "unclear"})

    assert err =~ "rol_unknown_gate ended without a clear verdict."
  end

  test "resolve_fingerprint falls back to role_run fingerprint when worktree_path is not a git repo", %{
    task: task,
    roles: roles
  } do
    {:ok, role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, _role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA"
      })

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        worktree_path: "/tmp/nonexistent_git_dir_#{System.unique_integer([:positive])}"
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        stage_fingerprint_head_sha: "fallback_sha",
        stage_fingerprint_dirty_digest: "fallback_digest"
      })

    output = "Approved.\n\nVERDICT: APPROVED"

    assert {:ok, %Task{stage: :qa},
            %RoleRun{stage_fingerprint_head_sha: "fallback_sha", stage_fingerprint_dirty_digest: "fallback_digest"}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})
  end

  test "settle_run registers detected question and preserves blocked state without advancing stage", %{
    task: task,
    roles: roles
  } do
    role = roles[:engineer]

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Working...\n[QUESTION: Which database engine?] [OPTIONS: PG, MySQL]"

    assert {:ok, %Task{stage: :engineer, stage_state: :blocked, question_id: "qst_" <> _rest = q_id},
            %RoleRun{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: output})

    assert byte_size(q_id) > 0
  end

  test "settle_run preserves blocked state when task was already blocked on question", %{task: task, roles: roles} do
    role = roles[:engineer]

    {:ok, %Question{id: expected_q_id}} =
      Pipeline.register_question(task, %{
        prompt: "Question prompt 14599?"
      })

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :blocked,
        question_id: expected_q_id
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        conversation_id: "sess_fixture",
        status: :blocked_on_input,
        started_at: DateTime.utc_now()
      })

    assert {:ok, %Task{stage: :engineer, stage_state: :blocked, question_id: ^expected_q_id},
            %RoleRun{status: :blocked_on_input, exit_code: 0}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0, output: "Exiting after ask"})
  end

  test "settle_run handles detected_question with atom and string keys and dropped question", %{
    project: project,
    task: task,
    roles: roles
  } do
    role = roles[:engineer]

    {:ok, task1} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run1} =
      Runs.create_role_run(%{
        task_id: task1.id,
        role_id: role.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    detector1 = %DetectedQuestion{prompt: "Atom key question?", options: ["A", "B"]}

    assert {:ok, %Task{stage_state: :blocked, question_id: "qst_" <> _rest1 = q_id1}, %RoleRun{status: :blocked_on_input}} =
             Pipeline.settle_run(task1, role_run1, %{exit_code: 0, detected_question: detector1})

    assert byte_size(q_id1) > 0

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14509",
      "identifier" => "TSK-14509",
      "title" => "Task 14509"
    })

    {:ok, issue_14509} = Issues.capture_issue(system_scope(), project, "Task 14509")

    {:ok, task2} = Pipeline.create_task(issue_14509, :product)

    {:ok, task2} = Pipeline.update_task(system_scope(), task2.id, %{issue_id: nil})

    {:ok, task2} =
      Pipeline.update_task(system_scope(), task2.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run2} =
      Runs.create_role_run(%{
        task_id: task2.id,
        role_id: role.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    detector2 = %DetectedQuestion{prompt: "String key question?", options: ["C", "D"]}

    assert {:ok, %Task{stage_state: :blocked, question_id: "qst_" <> _rest2 = q_id2}, %RoleRun{status: :blocked_on_input}} =
             Pipeline.settle_run(task2, role_run2, %{"exit_code" => 0, "detected_question" => detector2})

    assert byte_size(q_id2) > 0

    # Dropped registration when role_run has pending_answer
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_run_14510",
      "identifier" => "TSK-14510",
      "title" => "Task 14510"
    })

    {:ok, issue_14510} = Issues.capture_issue(system_scope(), project, "Task 14510")

    {:ok, task3} = Pipeline.create_task(issue_14510, :product)

    {:ok, task3} = Pipeline.update_task(system_scope(), task3.id, %{issue_id: nil})

    {:ok, task3} =
      Pipeline.update_task(system_scope(), task3.id, %{
        stage: :engineer,
        stage_state: :running
      })

    {:ok, role_run3} =
      Runs.create_role_run(%{
        task_id: task3.id,
        role_id: role.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        pending_answer: "Pending"
      })

    detector3 = %DetectedQuestion{prompt: "Drop this duplicate?", options: []}

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task3, role_run3, %{exit_code: 0, detected_question: detector3})
  end

  test "settle_run delegates %Run{kind: :chat} and %{kind: :chat} to SettleChatTurn", %{task: task, roles: roles} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :queued
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    run_struct = %Run{kind: :chat, role_run_id: role_run.id, task_id: task.id, status: :finished}

    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_run(task, role_run, run_struct)

    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_run(task, role_run, %{kind: :chat, exit_code: 0})
  end

  test "settling clean exit 0 for rebasing task restores previous state and refreshes mergeability", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{github_repo: "testorg/rebase_settle"})

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval,
        pr_number: 999,
        mergeability: :conflicting,
        pr_is_draft: false
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    mock_pull_request_state_success("testorg/rebase_settle", 999, mergeable: true, draft: false)

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              mergeability: :mergeable
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0}, token: "tok_test")
  end

  test "settling non-zero exit for rebasing task preserves is_rebasing for retries", %{task: task, roles: roles} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :queued
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        auto_retries: 0
      })

    assert {:ok,
            %Task{
              is_rebasing: true,
              stage_state: :failed,
              error: "Permanent error"
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 1, error: "Permanent error"})
  end

  test "settling clean exit for rebasing task falls back to updated_task if refresh_mergeability fails", %{
    project: project,
    task: task,
    roles: roles
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{github_repo: "testorg/rebase_settle_fail"})

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :ready_to_merge,
        stage_state: :running,
        is_rebasing: true,
        stage_state_before_rebase: :awaiting_approval,
        mergeability: :unknown,
        pr_number: 998,
        pr_is_draft: false
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: roles[:engineer].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    mock_pull_request_state_error("testorg/rebase_settle_fail", 998, 500, "Internal Server Error")

    assert {:ok,
            %Task{
              is_rebasing: false,
              stage_state: :awaiting_approval,
              stage_state_before_rebase: nil,
              mergeability: :unknown
            }, %RoleRun{status: :finished}} =
             Pipeline.settle_run(task, role_run, %{exit_code: 0}, token: "tok_test")
  end

  describe "settle_run at design stage" do
    test "designer run settlement fails when manifest is missing", %{task: task, roles: roles} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage: :design, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert err =~ "No design manifest found at"
    end

    test "designer run settlement populates task.design when manifest is valid", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14602",
          external_id: "lin_ws_settle_run_14602",
          token: "lin_api_token_settle_run_14602",
          webhook_secret: "whsec_settle_run_14602"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join([worktree_dir, ".rail", "design"])
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/canvas/v1",
          "version" => 1,
          "pickedKey" => nil,
          "directions" => [
            %{
              "key" => "dir-1",
              "title" => "Minimal Light",
              "notes" => "Clean aesthetic with spacious white layout",
              "stillPath" => ".rail/design/dir-1.png"
            },
            %{
              "key" => "dir-2",
              "title" => "Bold Dark",
              "notes" => "Dark mode with high contrast neon highlights",
              "stillPath" => ".rail/design/dir-2.png"
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      assert {:ok, %Task{stage: :design, stage_state: :awaiting_approval, error: nil}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      designs = Repo.all(from d in Rail.Artifacts.Schemas.Design, where: d.task_id == ^task.id)
      assert length(designs) == 1
      assert hd(designs).canvas_url == "https://claude.ai/canvas/v1"
    end

    test "fails when manifest no longer contains outstanding pickedKey", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14603",
          external_id: "lin_ws_settle_run_14603",
          token: "lin_api_token_settle_run_14603",
          webhook_secret: "whsec_settle_run_14603"
        })

      directions = [
        %{
          "key" => "dir-other",
          "title" => "Other",
          "notes" => "Notes",
          "stillPath" => ".rail/design/dir-1.png"
        }
      ]

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join([worktree_dir, ".rail", "design"])
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
          "pickedKey" => "dir-1",
          "directions" => directions
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Manifest missing picked direction: dir-1"
    end

    test "fails when manifest version is not incremented after a pick or revision", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14604",
          external_id: "lin_ws_settle_run_14604",
          token: "lin_api_token_settle_run_14604",
          webhook_secret: "whsec_settle_run_14604"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join([worktree_dir, ".rail", "design"])
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 1,
          "pickedKey" => "dir-1",
          "directions" => [
            %{
              "key" => "dir-1",
              "title" => "Minimal Light",
              "notes" => "Clean aesthetic with spacious white layout",
              "stillPath" => ".rail/design/dir-1.png"
            },
            %{
              "key" => "dir-2",
              "title" => "Bold Dark",
              "notes" => "Dark mode with high contrast neon highlights",
              "stillPath" => ".rail/design/dir-2.png"
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Manifest version must be incremented after a pick or revision."
    end

    test "fails when manifest is missing pickedKey after a pick", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14605",
          external_id: "lin_ws_settle_run_14605",
          token: "lin_api_token_settle_run_14605",
          webhook_secret: "whsec_settle_run_14605"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join([worktree_dir, ".rail", "design"])
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
          "pickedKey" => nil,
          "directions" => [
            %{
              "key" => "dir-1",
              "title" => "Minimal Light",
              "notes" => "Clean aesthetic with spacious white layout",
              "stillPath" => ".rail/design/dir-1.png"
            },
            %{
              "key" => "dir-2",
              "title" => "Bold Dark",
              "notes" => "Dark mode with high contrast neon highlights",
              "stillPath" => ".rail/design/dir-2.png"
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Design manifest is missing pickedKey (expected \"dir-1\")."
    end

    test "fails when manifest pickedKey does not match previously chosen direction", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14606",
          external_id: "lin_ws_settle_run_14606",
          token: "lin_api_token_settle_run_14606",
          webhook_secret: "whsec_settle_run_14606"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join([worktree_dir, ".rail", "design"])
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
          "pickedKey" => "dir-2",
          "directions" => [
            %{
              "key" => "dir-1",
              "title" => "Minimal Light",
              "notes" => "Clean aesthetic with spacious white layout",
              "stillPath" => ".rail/design/dir-1.png"
            },
            %{
              "key" => "dir-2",
              "title" => "Bold Dark",
              "notes" => "Dark mode with high contrast neon highlights",
              "stillPath" => ".rail/design/dir-2.png"
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, url_probe: fn _uri -> true end)

      assert err =~ "Design manifest pickedKey (dir-2) does not match chosen direction (dir-1)."
    end

    test "supports settling with scratch_path and valid transition", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14607",
          external_id: "lin_ws_settle_run_14607",
          token: "lin_api_token_settle_run_14607",
          webhook_secret: "whsec_settle_run_14607"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join([worktree_dir, ".rail", "design"])
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
          "pickedKey" => "dir-1",
          "directions" => [
            %{
              "key" => "dir-1",
              "title" => "Minimal Light",
              "notes" => "Clean aesthetic with spacious white layout",
              "stillPath" => ".rail/design/dir-1.png"
            },
            %{
              "key" => "dir-2",
              "title" => "Bold Dark",
              "notes" => "Dark mode with high contrast neon highlights",
              "stillPath" => ".rail/design/dir-2.png"
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(
                 task,
                 role_run,
                 %{exit_code: 0},
                 scratch_path: worktree_dir,
                 url_probe: fn _uri -> true end
               )
    end

    test "supports settling with scratch_dir and valid transition", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14608",
          external_id: "lin_ws_settle_run_14608",
          token: "lin_api_token_settle_run_14608",
          webhook_secret: "whsec_settle_run_14608"
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")
      design_dir = Path.join([worktree_dir, ".rail", "design"])
      File.mkdir_p!(design_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(design_dir, "dir-1.png"), "fake png content 1")
      File.write!(Path.join(design_dir, "dir-2.png"), "fake png content 2")

      File.write!(
        Path.join(design_dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/canvas-1",
          "version" => 2,
          "pickedKey" => "dir-1",
          "directions" => [
            %{
              "key" => "dir-1",
              "title" => "Minimal Light",
              "notes" => "Clean aesthetic with spacious white layout",
              "stillPath" => ".rail/design/dir-1.png"
            },
            %{
              "key" => "dir-2",
              "title" => "Bold Dark",
              "notes" => "Dark mode with high contrast neon highlights",
              "stillPath" => ".rail/design/dir-2.png"
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      # A previous design version already exists with dir-1 picked.

      manifest_path = Path.join(design_dir, "manifest.json")

      final_manifest = File.read!(manifest_path)

      base_manifest = Jason.decode!(final_manifest)

      File.write!(
        manifest_path,
        Jason.encode!(%{base_manifest | "version" => 1, "pickedKey" => "dir-1"})
      )

      mock_design_uploads(2)

      {:ok, _design} =
        Artifacts.capture_design(system_scope(), task, worktree_dir, url_probe: fn _url -> true end)

      File.write!(manifest_path, final_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(
                 task,
                 role_run,
                 %{exit_code: 0},
                 scratch_dir: worktree_dir,
                 url_probe: fn _uri -> true end
               )
    end
  end

  describe "settle_run at demo stage" do
    test "demo run settlement fails when manifest is missing", %{task: task, roles: roles} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert err =~ "Demo manifest not found at"
    end

    test "demo run settlement fails when worktree moved during recording", %{task: task, roles: roles} do
      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree)

      demo_dir = Path.join([worktree, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "frame-1.png"), "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: "prior_sha_before_move_#{original_sha}",
          stage_fingerprint_dirty_digest: original_digest
        })

      expected_err = "The worktree moved during the demo run."

      assert {:ok, %Task{stage_state: :failed, error: ^expected_err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "demo run settlement fails when worktree code outside .rail/ was modified during recording", %{
      task: task,
      roles: roles
    } do
      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree)

      demo_dir = Path.join([worktree, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "frame-1.png"), "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      File.write!(Path.join(worktree, "uncommitted.txt"), "dirtied worktree")

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: original_sha,
          stage_fingerprint_dirty_digest: original_digest
        })

      expected_err = "Worktree code outside .rail/ was modified during recording."

      assert {:ok, %Task{stage_state: :failed, error: ^expected_err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "demo run settlement succeeds when untracked frames exist in .rail/demo/", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14609",
          external_id: "lin_ws_settle_run_14609",
          token: "lin_api_token_settle_run_14609",
          webhook_secret: "whsec_settle_run_14609"
        })

      worktree = create_temp_git_repo()
      %{head_sha: original_sha, dirty_digest: original_digest} = Git.branch_fingerprint(worktree)

      demo_dir = Path.join([worktree, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      File.write!(Path.join(demo_dir, "frame-1.png"), "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      mock_demo_uploads(1)

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: original_sha,
          stage_fingerprint_dirty_digest: original_digest
        })

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert %Demo{version: 1, outcome: "recorded", stale: false} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "recorded outcome increments version, captures demo, and advances to ready_to_merge", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14610",
          external_id: "lin_ws_settle_run_14610",
          token: "lin_api_token_settle_run_14610",
          webhook_secret: "whsec_settle_run_14610"
        })

      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join([worktree_dir | List.wrap([".rail", "demo"])])
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 2,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Feature works as expected",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      # A stale v1 demo already exists; settling captures the v2 manifest on disk.
      demo_manifest_path = Path.join(demo_dir, "manifest.json")
      final_demo_manifest = File.read!(demo_manifest_path)
      base_demo_manifest = Jason.decode!(final_demo_manifest)

      File.write!(demo_manifest_path, Jason.encode!(%{base_demo_manifest | "version" => 1}))

      mock_demo_uploads(1)

      {:ok, _demo} = Artifacts.capture_demo(system_scope(), task, worktree_dir)

      {:ok, _demo} = Artifacts.mark_demo_stale(system_scope(), task)

      File.write!(demo_manifest_path, final_demo_manifest)

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      demos = Repo.all(from d in Demo, where: d.task_id == ^task.id, order_by: [asc: d.version])
      assert length(demos) == 2
      latest = List.last(demos)
      assert latest.version == 2
      assert latest.outcome == "recorded"
      refute latest.stale
    end

    test "declined outcome records demo with note and advances to ready_to_merge", %{task: task, roles: roles} do
      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join([worktree_dir | List.wrap([".rail", "demo"])])
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "declined",
          "note" => "Not suitable for demo recording",
          "segments" => []
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval, error: nil},
              %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert %Demo{version: 1, outcome: "declined", note: "Not suitable for demo recording"} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "failed outcome records failure and stops at demo failed", %{task: task, roles: roles} do
      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join([worktree_dir | List.wrap([".rail", "demo"])])
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "failed",
          "note" => "UI timed out during demo recording",
          "segments" => []
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})

      assert err =~ "UI timed out during demo recording"

      assert %Demo{version: 1, outcome: "failed", note: "UI timed out during demo recording"} =
               Repo.one(from d in Demo, where: d.task_id == ^task.id)
    end

    test "demo run non-zero exit code fails stage", %{task: task, roles: roles} do
      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          auto_retries: 0
        })

      assert {:ok, %Task{stage: :demo, stage_state: :failed, error: "Demo process crashed"}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 1, error: "Demo process crashed"})
    end

    test "supports settling demo with scratch_path and scratch_dir options", %{project: project, task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14611",
          external_id: "lin_ws_settle_run_14611",
          token: "lin_api_token_settle_run_14611",
          webhook_secret: "whsec_settle_run_14611"
        })

      scratch_1 = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join([scratch_1 | List.wrap([".rail", "demo"])])
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(scratch_1) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Feature works as expected",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      scratch_2 = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join([scratch_2 | List.wrap([".rail", "demo"])])
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(scratch_2) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 2,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Feature works as expected",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task1} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run1} =
        Runs.create_role_run(%{
          task_id: task1.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task1, role_run1, %{exit_code: 0}, scratch_path: scratch_1)

      LinearMock.mock_create_issue_success(%{
        "id" => "lin_task_settle_run_14511",
        "identifier" => "TSK-14511",
        "title" => "Task 14511"
      })

      {:ok, issue_14511} = Issues.capture_issue(system_scope(), project, "Task 14511")

      {:ok, task2} = Pipeline.create_task(issue_14511, :product)

      {:ok, task2} = Pipeline.update_task(system_scope(), task2.id, %{issue_id: nil})

      {:ok, task2} =
        Pipeline.update_task(system_scope(), task2.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run2} =
        Runs.create_role_run(%{
          task_id: task2.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task2, role_run2, %{exit_code: 0}, scratch_dir: scratch_2)
    end

    test "fails when manifest format is invalid during capture", %{task: task, roles: roles} do
      scratch_dir = create_temp_git_repo()
      demo_dir = Path.join([scratch_dir, ".rail", "demo"])
      File.mkdir_p!(demo_dir)

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{"version" => 1, "outcome" => "recorded"})
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, scratch_dir: scratch_dir)

      assert err =~ "segments"
    end

    test "fails when capture_demo fails during demo settlement", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14612",
          external_id: "lin_ws_settle_run_14612",
          token: "lin_api_token_settle_run_14612",
          webhook_secret: "whsec_settle_run_14612"
        })

      scratch_dir = create_temp_git_repo()
      demo_dir = Path.join([scratch_dir, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      frame = Path.join(demo_dir, "frame-1.png")
      File.write!(frame, "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      LinearMock.mock_file_upload_success(put_status: 500)

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, scratch_dir: scratch_dir)

      assert byte_size(err) > 0
    end

    test "resolves criteria from the issue description and handles nonexistent worktree path", %{
      task: task,
      issue: issue,
      roles: roles
    } do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14613",
          external_id: "lin_ws_settle_run_14613",
          token: "lin_api_token_settle_run_14613",
          webhook_secret: "whsec_settle_run_14613"
        })

      scratch_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join([scratch_dir | List.wrap([".rail", "demo"])])
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(scratch_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "First criterion",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
        set: [description: "Feature details\n\n## Acceptance criteria\n- First criterion"]
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          issue_id: issue.id,
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/nonexistent_wt_#{System.unique_integer([:positive])}"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: "head_fallback",
          stage_fingerprint_dirty_digest: "digest_fallback"
        })

      mock_demo_uploads(1)

      LinearMock.mock_create_comment_success(%{"id" => "lin_cmt_demo_criteria", "body" => "Demo"})

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, scratch_dir: scratch_dir)
    end

    test "handles non-git worktree directory gracefully during demo settlement", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14614",
          external_id: "lin_ws_settle_run_14614",
          token: "lin_api_token_settle_run_14614",
          webhook_secret: "whsec_settle_run_14614"
        })

      scratch_dir = Path.join("/tmp", "rail_non_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(scratch_dir)
      on_exit(fn -> File.rm_rf(scratch_dir) end)
      demo_dir = Path.join([scratch_dir, ".rail", "demo"])
      File.mkdir_p!(demo_dir)
      frame = Path.join(demo_dir, "frame-1.png")
      File.write!(frame, "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: scratch_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now(),
          stage_fingerprint_head_sha: "some_sha",
          stage_fingerprint_dirty_digest: "some_digest"
        })

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "resolves demo target from scratch_dir when task has no worktree_path", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14615",
          external_id: "lin_ws_settle_run_14615",
          token: "lin_api_token_settle_run_14615",
          webhook_secret: "whsec_settle_run_14615"
        })

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: "/tmp/rail-removed-worktree"
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      scratch_dir = Path.join([System.tmp_dir!(), "rail", task.project_id, "scratch", task.id])
      demo_dir = Path.join([scratch_dir, "demo"])
      File.mkdir_p!(demo_dir)
      frame = Path.join(demo_dir, "frame-1.png")
      File.write!(frame, "frame")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "AC 1",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0})
    end

    test "supports explicit criteria in opts when settling demo", %{task: task, roles: roles} do
      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Run Workspace 14616",
          external_id: "lin_ws_settle_run_14616",
          token: "lin_api_token_settle_run_14616",
          webhook_secret: "whsec_settle_run_14616"
        })

      worktree_dir = Path.join("/tmp", "rail_demo_wt_#{System.unique_integer([:positive])}")
      demo_dir = Path.join([worktree_dir | List.wrap([".rail", "demo"])])
      File.mkdir_p!(demo_dir)
      on_exit(fn -> File.rm_rf(worktree_dir) end)

      File.write!(Path.join(demo_dir, "frame-1.png"), "fake demo frame content 1")

      File.write!(
        Path.join(demo_dir, "manifest.json"),
        Jason.encode!(%{
          "version" => 1,
          "outcome" => "recorded",
          "note" => nil,
          "segments" => [
            %{
              "criterionIndex" => 1,
              "criterion" => "Explicit criterion",
              "outcome" => "recorded",
              "frames" => [%{"path" => "frame-1.png", "holdMs" => 1000, "caption" => "Step 1"}]
            }
          ]
        })
      )

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :demo,
          stage_state: :running,
          worktree_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: roles[:engineer].id,
          conversation_id: "sess_fixture",
          status: :running,
          started_at: DateTime.utc_now()
        })

      mock_demo_uploads(1)

      assert {:ok, %Task{stage: :ready_to_merge}, %RoleRun{status: :finished}} =
               Pipeline.settle_run(task, role_run, %{exit_code: 0}, criteria: ["Explicit criterion"])
    end
  end
end
