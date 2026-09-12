defmodule Rail.Pipeline.Utils.QaRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.PrepareScratch
  import Rail.Pipeline.Utils.QaLeadRunFinished
  import Rail.Pipeline.Utils.QaRunFinished
  import Rail.Pipeline.Utils.ReviewRunFinished
  import RailTest.PipelineHelpers

  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle QA Workspace",
        external_id: "lin_ws_settle_qa",
        token: "lin_api_token_settle_qa",
        webhook_secret: "whsec_settle_qa"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle QA Project 14606",
        github_repo: "org/settle-qa-14606",
        github_installation_id: 14_606,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_qa_14606",
        linear_team_key: "P14606",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-qa-14606",
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
      "id" => "lin_settle_qa_1",
      "identifier" => "S14606-1",
      "title" => "Settle QA Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle QA Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
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

    # A QA run has to leave a report before its verdict counts.
    qa_scratch = Path.join("/tmp", "rail_qa_pass_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(qa_scratch, "qa"))
    on_exit(fn -> File.rm_rf(qa_scratch) end)

    File.write!(
      Path.join([qa_scratch, "qa", "manifest.json"]),
      Jason.encode!(%{
        "commit" => "pass_sha",
        "session" => %{"pid" => 1234},
        "rows" => [
          %{"id" => "c1", "check" => "Login", "result" => "pass", "severity" => "cosmetic", "artifacts" => []}
        ]
      })
    )

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running,
        scratch_path: qa_scratch
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Test checklist passed.\n\nVERDICT: PASS"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa_lead,
              stage_state: :queued,
              outstanding_reports: [^role_qa_id]
            }, %Run{status: :finished}} =
             finish_qa_run(os_process)
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
    qa_dir = Path.join(scratch_dir, "qa")
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
      Pipeline.update_task(task, %{
        issue_id: issue.id,
        owner_user_id: user.id,
        stage: :qa,
        stage_state: :running
      })

    {:ok, %Run{id: run_id} = run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    mock_qa_uploads(1)
    LinearMock.mock_create_comment_success(%{"id" => "cmt_qa_settle", "body" => "QA comment"})

    output = "QA checklist completed.\n\nVERDICT: PASS"

    Runs.append_run_event(run, output)

    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa_lead,
              stage_state: :queued,
              outstanding_reports: [^role_qa_id]
            }, %Run{status: :finished, exit_code: 0}} =
             finish_qa_run(os_process)

    assert %QaReport{
             task_id: ^task_id,
             run_id: ^run_id,
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
    qa_dir = Path.join(scratch_dir, "qa")
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(Path.join(qa_dir, "screenshot.png"), "fake png content")
    File.write!(Path.join(qa_dir, "log.txt"), "All checks passed")

    File.write!(Path.join(qa_dir, "manifest.json"), "{broken_json")

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "VERDICT: PASS")

    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: err_msg
            }, %Run{status: :finished}} =
             finish_qa_run(os_process)

    assert err_msg =~ "Failed to parse QA manifest"
  end

  test "settles clean exit 0 for qa stage with a missing manifest by failing the stage", %{
    task: task,
    roles: roles
  } do
    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    scratch_dir = create_temp_git_repo()

    {:ok, %Task{id: task_id} = task} =
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "VERDICT: PASS")

    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: err_msg
            }, %Run{status: :finished}} =
             finish_qa_run(os_process)

    assert err_msg =~ "QA left no manifest"
  end

  test "settles clean exit 0 for qa stage reading the manifest from the task's scratch directory", %{
    task: task,
    roles: roles
  } do
    scratch_dir = Path.join("/tmp", "rail_qa_base_#{System.unique_integer([:positive])}")
    qa_dir = Path.join(scratch_dir, "qa")
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(scratch_dir) end)

    File.write!(
      Path.join(qa_dir, "manifest.json"),
      Jason.encode!(%{
        "commit" => "scratch_sha",
        "session" => %{"pid" => 1234},
        "rows" => [
          %{"id" => "c1", "check" => "Login", "result" => "pass", "severity" => "cosmetic", "artifacts" => []}
        ]
      })
    )

    {:ok, task} =
      Pipeline.update_task(task, %{stage: :qa, stage_state: :running})

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: roles[:qa].id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run, "VERDICT: PASS")

    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :qa_lead}, %Run{}} =
             finish_qa_run(os_process)

    assert %QaReport{commit: "scratch_sha"} = Repo.one(from q in QaReport, where: q.task_id == ^task.id)
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
    qa_dir = Path.join(scratch_dir, "qa")
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
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running,
        rework_cycles: 0,
        rework_cycles_by_gate: %{}
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _prior_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_eng",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output = "Button is broken.\n\nVERDICT: FAIL"

    Runs.append_run_event(run, output)

    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :engineer,
              stage_state: :queued,
              rework_cycles: 1
            }, %Run{status: :finished}} =
             finish_qa_run(os_process)

    assert %QaReport{commit: "fail_qa_commit"} = Repo.one(from q in QaReport, where: q.task_id == ^task_id)

    eng_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
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
    qa_dir = Path.join(scratch_dir, "qa")
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
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Plug.Conn.send_resp(conn, 500, "Upload error")
    end)

    Runs.append_run_event(run, "VERDICT: PASS")

    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :qa,
              stage_state: :failed,
              error: err_msg
            }, %Run{status: :finished}} =
             finish_qa_run(os_process)

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
    qa_dir = Path.join(qa_scratch_dir, "qa")
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
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running
      })

    {:ok, run_qa} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    # Step 1: Settle QA run
    Runs.append_run_event(run_qa, "VERDICT: PASS")

    {:ok, _persisted} = Pipeline.update_task(task, %{scratch_path: qa_scratch_dir})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run_qa.id,
        task_id: run_qa.task_id,
        stream_path: "/tmp/settle_qa/#{run_qa.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :qa_lead, stage_state: :queued} = task_lead_queued, _rr} =
             finish_qa_run(os_process)

    # Step 2: Scratch prepare for QA Lead
    lead_scratch_dir = create_temp_git_repo()
    assert {:ok, ^lead_scratch_dir} = prepare_scratch(%{task_lead_queued | scratch_path: lead_scratch_dir})

    # Verify materialization into lead scratch dir
    assert File.exists?(Path.join([lead_scratch_dir, "qa", "manifest.json"]))
    assert File.read!(Path.join([lead_scratch_dir, "qa", "proof.txt"])) == "FLOW PROOF TEXT"

    # Step 3: Settle QA Lead run
    {:ok, run_lead} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run_lead, "VERDICT: PASS")

    {:ok, _persisted} = Pipeline.update_task(task_lead_queued, %{scratch_path: lead_scratch_dir})

    run_2 =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run_lead.id,
        task_id: run_lead.task_id,
        stream_path: "/tmp/settle_qa/#{run_lead.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(run_2, %{exit_code: 0})

    assert {:ok, %Task{stage: :ready_to_merge, stage_state: :awaiting_approval}, _rr2} =
             finish_qa_lead_run(run_2)
  end

  test "settles gate with changes_requested parking for human when global rework ceiling is reached", %{
    task: task,
    roles: roles
  } do
    {:ok, role_qa} =
      Roles.update_role(system_scope(), roles[:qa], %{
        name: "QA Tester"
      })

    # A QA run has to leave a report before its verdict counts.
    qa_scratch = Path.join("/tmp", "rail_qa_gate_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(qa_scratch, "qa"))
    on_exit(fn -> File.rm_rf(qa_scratch) end)

    File.write!(
      Path.join([qa_scratch, "qa", "manifest.json"]),
      Jason.encode!(%{
        "commit" => "gate_sha",
        "session" => %{"pid" => 1234},
        "rows" => [
          %{"id" => "c1", "check" => "Login", "result" => "pass", "severity" => "cosmetic", "artifacts" => []}
        ]
      })
    )

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running,
        scratch_path: qa_scratch,
        rework_cycles: 5,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{"other_gate" => 2, role_qa.id => 1}
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA failure.\n\nVERDICT: FAILED"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage_state: :awaiting_approval,
              rework_cycles: 5,
              error: err
            }, %Run{status: :finished}} =
             finish_qa_run(os_process)

    assert err =~ "QA Tester is still requesting changes after 1 rework cycle."
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

    # A QA run has to leave a report before its verdict counts.
    File.mkdir_p!(Path.join(git_repo, "qa"))

    File.write!(
      Path.join([git_repo, "qa", "manifest.json"]),
      Jason.encode!(%{
        "commit" => "gate_sha",
        "session" => %{"pid" => 1234},
        "rows" => [
          %{"id" => "c1", "check" => "Login", "result" => "pass", "severity" => "cosmetic", "artifacts" => []}
        ]
      })
    )

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :qa,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo,
        scratch_path: git_repo
      })

    {:ok, _run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now(),
        pending_answer: "Prior lead notes"
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "QA passed cleanly.\n\nVERDICT: PASS"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_qa/#{run.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :qa_lead, stage_state: :queued}, %Run{stage_fingerprint_head_sha: head_sha}} =
             finish_qa_run(os_process)

    lead_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_lead.id)

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

    {:ok, task2} = Pipeline.update_task(task2, %{issue_id: nil})

    {:ok, %Task{id: task_id2} = _task2} =
      Pipeline.update_task(task2, %{
        stage: :qa_lead,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, run2} =
      Runs.create_run(%{
        task_id: task_id2,
        role_id: role_lead.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _demo_run} =
      Runs.create_run(%{
        task_id: task_id2,
        role_id: role_demo.id,
        conversation_id: "sess_demo",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output2 = "QA Lead pass.\n\nVERDICT: PASS"

    Runs.append_run_event(run2, output2)

    run_4 =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run2.id,
        task_id: run2.task_id,
        stream_path: "/tmp/settle_qa/#{run2.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(run_4, %{exit_code: 0})

    assert {:ok, %Task{stage: :demo, stage_state: :queued}, %Run{stage_fingerprint_head_sha: head_sha2}} =
             finish_qa_lead_run(run_4)

    demo_run = Repo.one(from r in Run, where: r.task_id == ^task_id2 and r.role_id == ^role_demo.id)
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

    {:ok, task3} = Pipeline.update_task(task3, %{issue_id: nil})

    {:ok, %Task{id: task_id3} = _task3} =
      Pipeline.update_task(task3, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, run3} =
      Runs.create_run(%{
        task_id: task_id3,
        role_id: role_rev3.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run3, "VERDICT: APPROVED")

    run_4 =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run3.id,
        task_id: run3.task_id,
        stream_path: "/tmp/settle_qa/#{run3.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(run_4, %{exit_code: 0})

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %Run{status: :finished}} =
             finish_review_run(run_4)

    # Part D: Gate unclear with unknown role ID falls back to to_string(role_id)
    unknown_role_id = "rol_unknown_gate"

    {:ok, run_unknown} =
      Runs.create_run(%{
        task_id: task_id3,
        role_id: unknown_role_id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run_unknown, "unclear")

    run_4 =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run_unknown.id,
        task_id: run_unknown.task_id,
        stream_path: "/tmp/settle_qa/#{run_unknown.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(run_4, %{exit_code: 0})

    assert {:ok, %Task{stage_state: :awaiting_approval, error: err}, %Run{status: :finished}} =
             finish_review_run(run_4)

    assert err =~ "rol_unknown_gate ended without a clear verdict."
  end
end
