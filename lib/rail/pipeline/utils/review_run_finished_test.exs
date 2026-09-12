defmodule Rail.Pipeline.Utils.ReviewRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.ReviewRunFinished

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
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Review Workspace",
        external_id: "lin_ws_settle_review",
        token: "lin_api_token_settle_review",
        webhook_secret: "whsec_settle_review"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Settle Review Project 14605",
        github_repo: "org/settle-review-14605",
        github_installation_id: 14_605,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_settle_review_14605",
        linear_team_key: "P14605",
        default_branch: "main",
        clone_path: "/tmp/repos/settle-review-14605",
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
      "id" => "lin_settle_review_1",
      "identifier" => "S14605-1",
      "title" => "Settle Review Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Settle Review Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    # These tests exercise stage transitions, not Linear publishing.
    {:ok, task} = Pipeline.update_task(task, %{issue_id: nil})

    %{backend: backend, project: project, issue: issue, task: task, roles: roles}
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

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running,
        worktree_path: git_repo
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Code looks great!\n\nVERDICT: APPROVED"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}.ndjson",
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
              stage_state: :queued,
              outstanding_reports: [^role_rev_id]
            },
            %Run{
              status: :finished,
              exit_code: 0,
              stage_fingerprint_head_sha: head_sha,
              stage_fingerprint_dirty_digest: dirty_digest
            }} = finish_review_run(os_process)

    assert is_binary(head_sha) and head_sha != ""
    assert is_binary(dirty_digest) and dirty_digest != ""
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

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{},
        outstanding_reports: [role_prior.id]
      })

    {:ok, prior_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_prior.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(prior_run, "Prior QA note: button is off-center.")

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _eng_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_eng",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output = "Please fix test coverage.\n\nVERDICT: CHANGES REQUESTED"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}.ndjson",
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
              rework_cycles: 1,
              rework_cycles_by_gate: %{^role_rev_id => 1},
              outstanding_reports: []
            }, %Run{status: :finished}} =
             finish_review_run(os_process)

    engineer_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
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

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 3,
        rework_budget_base: 0,
        rework_cycles_by_gate: %{role_rev.id => 3}
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Still not fixed.\n\nVERDICT: FAIL"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok,
            %Task{
              id: ^task_id,
              stage: :review,
              stage_state: :awaiting_approval,
              rework_cycles: 3,
              error: err
            }, %Run{status: :finished}} =
             finish_review_run(os_process)

    assert err =~ "Reviewer is still requesting changes after 3 rework cycles."
    assert err =~ "Send back to Engineer to have them addressed, or Skip"
  end

  test "settles gate with unclear verdict parking for human", %{task: task, roles: roles} do
    {:ok, %Role{id: role_rev_id} = role_rev} =
      Roles.update_role(system_scope(), roles[:review], %{
        name: "Reviewer"
      })

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Here are some notes but no verdict keyword."

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}.ndjson",
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
              error: err,
              outstanding_reports: [^role_rev_id]
            }, %Run{status: :finished}} =
             finish_review_run(os_process)

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

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, _qa_run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_qa.id,
        conversation_id: "sess_qa",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    output = "Rework resolved nicely.\n\nVERDICT: APPROVED"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %Run{stage_fingerprint_head_sha: head_sha}} =
             finish_review_run(os_process)

    qa_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_qa.id)
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

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 1,
        worktree_path: git_repo
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Rework resolved nicely.\n\nVERDICT: APPROVED"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :qa, stage_state: :queued}, %Run{}} =
             finish_review_run(os_process)

    assert Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_qa.id) == nil
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

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0
      })

    {:ok, _run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_eng.id,
        conversation_id: "sess_fixture",
        status: :finished,
        started_at: DateTime.utc_now(),
        pending_answer: "Old engineer notes"
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    output = "Please fix tests.\n\nVERDICT: CHANGES REQUESTED"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}, %Run{status: :finished}} =
             finish_review_run(os_process)

    eng_run = Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_eng.id)
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

    {:ok, task2} = Pipeline.update_task(task2, %{issue_id: nil})

    {:ok, %Task{id: task_id2} = _task2} =
      Pipeline.update_task(task2, %{
        stage: :review,
        stage_state: :running,
        rework_cycles: 0,
        rework_budget_base: 0
      })

    {:ok, run2} =
      Runs.create_run(%{
        task_id: task_id2,
        role_id: role_rev2.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now()
      })

    Runs.append_run_event(run2, output)

    run_2 =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run2.id,
        task_id: run2.task_id,
        stream_path: "/tmp/settle_review/#{run2.id}-#{System.unique_integer([:positive])}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _st, _srr} = Pipeline.settle_run(run_2, %{exit_code: 0})

    assert {:ok, %Task{stage: :engineer, stage_state: :queued}, %Run{status: :finished}} =
             finish_review_run(run_2)
  end

  test "resolve_fingerprint falls back to run fingerprint when worktree_path is not a git repo", %{
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

    {:ok, %Task{id: task_id} = _task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :running,
        worktree_path: "/tmp/nonexistent_git_dir_#{System.unique_integer([:positive])}"
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_rev.id,
        conversation_id: "sess_fixture",
        status: :running,
        started_at: DateTime.utc_now(),
        stage_fingerprint_head_sha: "fallback_sha",
        stage_fingerprint_dirty_digest: "fallback_digest"
      })

    output = "Approved.\n\nVERDICT: APPROVED"

    Runs.append_run_event(run, output)

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/settle_review/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    {:ok, _settled_task, _settled_run} = Pipeline.settle_run(os_process, %{exit_code: 0})

    assert {:ok, %Task{stage: :qa},
            %Run{stage_fingerprint_head_sha: "fallback_sha", stage_fingerprint_dirty_digest: "fallback_digest"}} =
             finish_review_run(os_process)
  end
end
