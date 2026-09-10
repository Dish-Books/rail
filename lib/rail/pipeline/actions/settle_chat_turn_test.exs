defmodule Rail.Pipeline.Actions.SettleChatTurnTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Artifacts.Schemas.Design
  alias Rail.Domain.TaskUsage
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Settle Chat Workspace",
        external_id: "lin_ws_settle_chat",
        token: "lin_api_token_settle_chat",
        webhook_secret: "whsec_settle_chat"
      })

    repo_dir = create_temp_git_repo()

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        linear_workspace_id: workspace.id,
        name: "Settle Chat Project 11002",
        github_repo: "org/settle-chat-11002",
        github_installation_id: 11_002,
        linear_team_id: "team_settle_chat_11002",
        linear_team_key: "P11002",
        clone_path: repo_dir,
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        default_branch: "main"
      })

    {:ok, eng_role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 11006",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11006.",
        stage: :engineer,
        cli_backend: :claude
      })

    {:ok, rev_role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 11007",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11007.",
        stage: :review,
        cli_backend: :claude
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_chat_11030",
      "identifier" => "TSK-11030",
      "title" => "Task 11030"
    })

    {:ok, issue_11030} = Issues.capture_issue(system_scope(), project, "Task 11030")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_settle_chat_11030"})

    {:ok, task} = Pipeline.create_task(issue_11030)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :review,
        stage_state: :awaiting_approval,
        worktree_path: repo_dir
      })

    %{
      workspace: workspace,
      project: project,
      eng_role: eng_role,
      rev_role: rev_role,
      task: task,
      repo_dir: repo_dir
    }
  end

  test "returns not_found when task or role run does not exist" do
    assert {:error, :not_found} =
             Pipeline.settle_chat_turn("tsk_000000000000000000000000", "rr_000000000000000000000000")
  end

  test "settles clean chat turn, clears active_chat_role_id and pending_chat, and accumulates chat_usage", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    initial_usage = %TaskUsage{input_tokens: 50, output_tokens: 25, total_cost: Decimal.new("0.01")}

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev-1",
        output: "Original review output",
        pending_chat: "Can you clarify finding 1?",
        chat_fingerprint_head_sha: "head123",
        chat_fingerprint_dirty_digest: "digest123",
        chat_usage: initial_usage
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: rev_role_id}) |> Repo.update()

    {:ok, run} =
      Runs.start_run(role_run_id, :chat, ["/bin/sleep", "5"], skip_follower: true)

    turn_usage = %TaskUsage{input_tokens: 100, output_tokens: 50, total_cost: Decimal.new("0.05")}

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "Hello from reviewer agent",
      usage: turn_usage,
      run: run
    }

    assert {:ok, %Task{active_chat_role_id: nil}, %RoleRun{pending_chat: nil, chat_usage: %TaskUsage{}}} =
             Pipeline.settle_chat_turn(task.id, role_run_id, outcome)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_settled}}

    refreshed_task = Repo.get!(Task, task_id)
    refreshed_role_run = Repo.get!(RoleRun, role_run_id)

    assert %Task{
             stage: :review,
             stage_state: :awaiting_approval,
             active_chat_role_id: nil,
             error: nil
           } = refreshed_task

    assert %RoleRun{
             status: :finished,
             output: "Original review output",
             pending_chat: nil,
             chat_fingerprint_head_sha: nil,
             chat_fingerprint_dirty_digest: nil,
             chat_usage: %TaskUsage{input_tokens: 150, output_tokens: 75}
           } = refreshed_role_run

    refreshed_run = Repo.get!(Run, run.id)
    assert refreshed_run.status == :finished
  end

  test "review chat returning VERDICT line does not advance stage or touch output", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-verdict",
        output: "Original verdict: approved"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: rev_role_id}) |> Repo.update()

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "I still have concerns.\nVERDICT: CHANGES REQUESTED",
      usage: %TaskUsage{input_tokens: 20, output_tokens: 10}
    }

    assert {:ok, %Task{stage: :review, stage_state: :awaiting_approval}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, role_run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    refreshed_role_run = Repo.get!(RoleRun, role_run_id)

    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :awaiting_approval
    assert refreshed_role_run.output == "Original verdict: approved"
  end

  test "chat turn emitting [QUESTION:] does not file question or block stage", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-question"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: rev_role_id}) |> Repo.update()

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "[QUESTION: Do you prefer approach A or B?]",
      usage: %TaskUsage{input_tokens: 30, output_tokens: 15}
    }

    assert {:ok, %Task{stage_state: :awaiting_approval, question_id: nil}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, role_run_id, outcome)

    questions = Repo.all(from q in Question, where: q.task_id == ^task_id)
    assert questions == []
  end

  test "engineer modifying files resets to engineer awaiting_approval (first pass)", %{
    task: %Task{id: task_id} = task,
    eng_role: %Role{id: eng_role_id},
    repo_dir: repo_dir
  } do
    before_fp = Rail.Git.branch_fingerprint(repo_dir)

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng-mod",
        chat_fingerprint_head_sha: before_fp.head_sha,
        chat_fingerprint_dirty_digest: before_fp.dirty_digest
      })

    {:ok, task} =
      task
      |> Task.changeset(%{
        stage: :review,
        stage_state: :awaiting_approval,
        rework_cycles: 0,
        active_chat_role_id: eng_role_id
      })
      |> Repo.update()

    File.write!(Path.join(repo_dir, "modified_by_eng.txt"), "engineer modification\n")

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "I made the code change.",
      usage: %TaskUsage{input_tokens: 100, output_tokens: 50}
    }

    assert {:ok, %Task{stage: :engineer, stage_state: :awaiting_approval}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, role_run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :engineer
    assert refreshed_task.stage_state == :awaiting_approval

    events = Runs.list_run_events(role_run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[rail] Branch modified during chat; reset pipeline to Engineer."
           end)
  end

  test "engineer modifying files with has_been_reworked queues review and appends evidence commit line", %{
    task: %Task{id: task_id} = task,
    eng_role: %Role{id: eng_role_id},
    rev_role: %Role{id: rev_role_id},
    repo_dir: repo_dir
  } do
    before_fp = Rail.Git.branch_fingerprint(repo_dir)

    {:ok, %RoleRun{id: eng_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng-rework",
        chat_fingerprint_head_sha: before_fp.head_sha,
        chat_fingerprint_dirty_digest: before_fp.dirty_digest
      })

    {:ok, %RoleRun{id: rev_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev-rework",
        pending_answer: "Previous review notes"
      })

    {:ok, task} =
      task
      |> Task.changeset(%{
        stage: :review,
        stage_state: :awaiting_approval,
        rework_cycles: 1,
        outstanding_reports: ["qa"],
        active_chat_role_id: eng_role_id
      })
      |> Repo.update()

    File.write!(Path.join(repo_dir, "reworked_mod.txt"), "reworked content\n")

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "Fixed the reported issue.",
      usage: %TaskUsage{input_tokens: 120, output_tokens: 60}
    }

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, eng_role_run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :queued
    assert refreshed_task.outstanding_reports == []

    eng_events = Runs.list_run_events(eng_role_run_id)

    assert Enum.any?(eng_events, fn %RunEvent{line: line} ->
             line == "[rail] Branch modified during chat; queued for review."
           end)

    refreshed_rev = Repo.get!(RoleRun, rev_role_run_id)
    assert refreshed_rev.pending_answer =~ "Previous review notes"
    assert refreshed_rev.pending_answer =~ "The reworked change is commit"
    assert refreshed_rev.pending_answer =~ "Every check you report on this pass must have been run against it"
  end

  test "reviewer modifying files logs notice and does not reset pipeline", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id},
    repo_dir: repo_dir
  } do
    before_fp = Rail.Git.branch_fingerprint(repo_dir)

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev-mod",
        chat_fingerprint_head_sha: before_fp.head_sha,
        chat_fingerprint_dirty_digest: before_fp.dirty_digest
      })

    {:ok, task} =
      task
      |> Task.changeset(%{
        stage: :review,
        stage_state: :awaiting_approval,
        active_chat_role_id: rev_role_id
      })
      |> Repo.update()

    File.write!(Path.join(repo_dir, "reviewer_mod.txt"), "reviewer touched file\n")

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "Left a comment and touched a file",
      usage: %TaskUsage{input_tokens: 40, output_tokens: 20}
    }

    assert {:ok, %Task{stage: :review, stage_state: :awaiting_approval}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, role_run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :awaiting_approval

    events = Runs.list_run_events(role_run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[rail] Changes were made to the branch, but only Engineer changes reset the pipeline."
           end)
  end

  test "failed chat exit logs notice and does not fail task stage", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-fail"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: rev_role_id}) |> Repo.update()

    outcome = %{
      exit_code: 1,
      error: "Command failed: exit 1",
      output: ""
    }

    assert {:ok, %Task{stage: :review, stage_state: :awaiting_approval}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, role_run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :awaiting_approval
    assert refreshed_task.active_chat_role_id == nil
    assert refreshed_task.error == nil

    events = Runs.list_run_events(role_run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line =~ "[rail] That turn was not delivered: Command failed: exit 1"
           end)
  end

  test "dispatches queued pending_chat when task becomes idle after settlement", %{
    task: %Task{id: task_id} = task,
    eng_role: %Role{id: eng_role_id},
    rev_role: %Role{id: rev_role_id}
  } do
    stub_bin = create_chat_stub_cli(conversation_id: "sess-rev-queued")

    {:ok, %RoleRun{id: eng_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng-current"
      })

    {:ok, %RoleRun{id: rev_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev-queued",
        pending_chat: "Queued turn for reviewer"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: eng_role_id}) |> Repo.update()

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "Done with eng chat",
      usage: %TaskUsage{input_tokens: 10, output_tokens: 10}
    }

    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, eng_role_run_id, outcome,
               executable: stub_bin,
               async: false
             )

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.active_chat_role_id == rev_role_id

    rev_runs = Runs.list_runs(role_run_id: rev_role_run_id)
    assert length(rev_runs) == 1
    assert hd(rev_runs).kind == :chat
  end

  test "settle_run delegates to settle_chat_turn when run kind is :chat", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-chat-delegate"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: rev_role_id}) |> Repo.update()

    {:ok, run} =
      Runs.start_run(role_run_id, :chat, ["/bin/sleep", "5"], skip_follower: true)

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "Chat reply",
      usage: %TaskUsage{input_tokens: 30, output_tokens: 15},
      run: run
    }

    assert {:ok, %Task{active_chat_role_id: nil}, %RoleRun{chat_usage: %TaskUsage{input_tokens: 30}}} =
             Pipeline.settle_run(task.id, role_run_id, outcome)
  end

  test "settle_run dispatches queued pending_chat when stage run completes and task is idle", %{
    task: %Task{id: task_id} = task,
    eng_role: %Role{id: eng_role_id},
    rev_role: %Role{id: rev_role_id}
  } do
    stub_bin = create_chat_stub_cli(conversation_id: "sess-rev-stage-finish")

    {:ok, %RoleRun{id: eng_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng-stage"
      })

    {:ok, %RoleRun{id: rev_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev-stage-finish",
        pending_chat: "Queued question while stage was running"
      })

    {:ok, task} =
      task
      |> Task.changeset(%{stage: :engineer, stage_state: :running})
      |> Repo.update()

    {:ok, stage_run} =
      Runs.start_run(eng_role_run_id, :stage, ["/bin/sleep", "5"], skip_follower: true)

    outcome = %{
      exit_code: 0,
      error: nil,
      output: "Engineer stage finished",
      usage: %TaskUsage{input_tokens: 500, output_tokens: 200},
      run: stage_run
    }

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %RoleRun{}} =
             Pipeline.settle_run(task.id, eng_role_run_id, outcome,
               executable: stub_bin,
               async: false
             )

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.active_chat_role_id == rev_role_id

    rev_runs = Runs.list_runs(role_run_id: rev_role_run_id)
    assert length(rev_runs) == 1
    assert hd(rev_runs).kind == :chat
  end

  test "settle_chat_turn when branch modified and no review role run exists creates new review role run", %{
    task: task,
    eng_role: eng_role
  } do
    {:ok, %RoleRun{id: eng_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: eng_role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-no-rev-rr",
        chat_fingerprint_head_sha: "head_before_123",
        chat_fingerprint_dirty_digest: "digest_before_123"
      })

    {:ok, task} =
      task
      |> Task.changeset(%{rework_cycles: 1, stage: :review, stage_state: :queued})
      |> Repo.update()

    # Modify file in worktree
    File.write!(Path.join(task.worktree_path, "rework_new.txt"), "rework change\n")

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, eng_role_run_id, %{exit_code: 0})
  end

  test "settle_chat_turn when branch modified and project has no review role", %{
    task: orig_task,
    workspace: workspace
  } do
    {:ok, proj_no_rev} =
      Projects.create_project(system_scope(), %{
        linear_workspace_id: workspace.id,
        name: "Settle Chat Project 11003",
        github_repo: "org/settle-chat-11003",
        github_installation_id: 11_003,
        linear_team_id: "team_settle_chat_11003",
        linear_team_key: "P11003",
        clone_path: orig_task.worktree_path,
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        default_branch: "main"
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_chat_11031",
      "identifier" => "TSK-11031",
      "title" => "Task 11031"
    })

    {:ok, issue_11031} = Issues.capture_issue(system_scope(), proj_no_rev, "Task 11031")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_settle_chat_11031"})

    {:ok, task_no_rev} = Pipeline.create_task(issue_11031)

    {:ok, task_no_rev} =
      Pipeline.update_task(system_scope(), task_no_rev.id, %{
        stage: :review,
        stage_state: :queued,
        worktree_path: orig_task.worktree_path,
        rework_cycles: 1
      })

    {:ok, eng_role_no_rev} =
      Roles.create_role(system_scope(), proj_no_rev, %{
        name: "Role 11008",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11008.",
        stage: :engineer
      })

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_no_rev.id,
        role_id: eng_role_no_rev.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        chat_fingerprint_head_sha: "head_before_456",
        chat_fingerprint_dirty_digest: "digest_before_456"
      })

    File.write!(Path.join(task_no_rev.worktree_path, "no_rev.txt"), "data\n")

    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task_no_rev, role_run, %{exit_code: 0})
  end

  test "settle_chat_turn resolves string-keyed maps, raw maps, and finishes in-flight run", %{
    task: task,
    eng_role: eng_role
  } do
    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: eng_role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        exit_code: 42,
        error: "role run error"
      })

    {:ok, in_flight_run} =
      Runs.start_run(role_run.id, :chat, ["/bin/sleep", "5"], skip_follower: true)

    # Finishing in_flight_run when passed as %Run{}
    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task.id, role_run.id, in_flight_run)

    assert Repo.get!(Run, in_flight_run.id).status == :finished

    # String-keyed exit_code, error, usage map
    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task.id, role_run.id, %{
               "exit_code" => 0,
               "error" => "ignored error",
               "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
             })

    # Map usage under :usage
    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task.id, role_run.id, %{
               exit_code: 0,
               usage: %{input_tokens: 15, output_tokens: 5}
             })

    # %TaskUsage{} under "usage"
    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task.id, role_run.id, %{
               "usage" => %TaskUsage{input_tokens: 10, output_tokens: 5}
             })

    # Fallback to role_run exit code and error
    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, role_run)

    # Fallback exit code 0 when neither outcome nor role_run has integer exit code
    {:ok, role_run_nil_code} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: eng_role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        exit_code: nil
      })

    assert {:ok, %Task{}, %RoleRun{}} =
             Pipeline.settle_chat_turn(task, role_run_nil_code, %{exit_code: nil})

    # Invalid targets return :not_found
    assert {:error, :not_found} = Pipeline.settle_chat_turn(12_345, role_run)
    assert {:error, :not_found} = Pipeline.settle_chat_turn(task, 12_345)
  end

  describe "settle_chat_turn at design stage" do
    test "a chat turn that rewrites the manifest lands the design", %{project: _project, task: task, workspace: workspace} do
      {:ok, project} =
        Projects.create_project(system_scope(), %{
          linear_workspace_id: workspace.id,
          name: "Settle Chat Project 11004",
          github_repo: "org/settle-chat-11004",
          github_installation_id: 11_004,
          linear_team_id: "team_settle_chat_11004",
          linear_team_key: "P11004",
          clone_path: "/tmp/repos/settle-chat-11004",
          linear_state_ids: %{
            "triage" => "st_triage",
            "backlog" => "st_backlog",
            "in_progress" => "st_in_progress",
            "done" => "st_done",
            "canceled" => "st_canceled"
          }
        })

      {:ok, _workspace} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Settle Chat Workspace 11032",
          external_id: "lin_ws_settle_chat_11032",
          token: "lin_api_token_settle_chat_11032",
          webhook_secret: "whsec_settle_chat_11032"
        })

      {:ok, designer_role} =
        Roles.create_role(system_scope(), project, %{
          name: "Designer",
          model: "claude-3-7-sonnet",
          system_prompt: "You are an expert agent for role 11009.",
          stage: :design
        })

      design_manifest =
        Jason.encode!(%{
          "canvasUrl" => "https://claude.ai/design/abc",
          "version" => 1,
          "pickedKey" => nil,
          "directions" => [
            %{"key" => "dir-1", "title" => "Minimal Light", "notes" => "Clean", "stillPath" => "dir-1.png"},
            %{"key" => "dir-2", "title" => "Bold Dark", "notes" => "Contrast", "stillPath" => "dir-2.png"}
          ]
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")

      expect(File, :read, 4, fn _path -> {:ok, design_manifest} end)
      expect(File, :exists?, 7, fn _path -> true end)
      expect(File, :stat, 4, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :failed,
          error: "Initial canvas 404",
          worktree_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: designer_role.id,
          status: :finished,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}, %RoleRun{}} =
               Pipeline.settle_chat_turn(
                 task,
                 role_run,
                 %{exit_code: 0},
                 before_design_stamp: "stale-stamp-123",
                 url_probe: fn _uri -> true end
               )

      reloaded = Repo.get!(Task, task.id)
      assert reloaded.stage_state == :awaiting_approval
      assert is_nil(reloaded.error)

      design = Repo.one(from d in Design, where: d.task_id == ^task.id)
      assert design.canvas_url == "https://claude.ai/design/abc"
    end

    test "a chat turn that leaves the manifest alone changes nothing", %{
      project: _project,
      task: task,
      workspace: workspace
    } do
      {:ok, project} =
        Projects.create_project(system_scope(), %{
          linear_workspace_id: workspace.id,
          name: "Settle Chat Project 11005",
          github_repo: "org/settle-chat-11005",
          github_installation_id: 11_005,
          linear_team_id: "team_settle_chat_11005",
          linear_team_key: "P11005",
          clone_path: "/tmp/repos/settle-chat-11005",
          linear_state_ids: %{
            "triage" => "st_triage",
            "backlog" => "st_backlog",
            "in_progress" => "st_in_progress",
            "done" => "st_done",
            "canceled" => "st_canceled"
          }
        })

      {:ok, designer_role} =
        Roles.create_role(system_scope(), project, %{
          name: "Designer",
          model: "claude-3-7-sonnet",
          system_prompt: "You are an expert agent for role 11010.",
          stage: :design
        })

      design_manifest =
        Jason.encode!(%{
          "canvasUrl" => "invalid-url",
          "version" => 1,
          "pickedKey" => nil,
          "directions" => [
            %{"key" => "dir-1", "title" => "Minimal Light", "notes" => "Clean", "stillPath" => "dir-1.png"},
            %{"key" => "dir-2", "title" => "Bold Dark", "notes" => "Contrast", "stillPath" => "dir-2.png"}
          ]
        })

      worktree_dir = Path.join("/tmp", "rail_design_wt_#{System.unique_integer([:positive])}")

      expect(File, :read, 1, fn _path -> {:ok, design_manifest} end)
      expect(File, :exists?, 2, fn _path -> true end)

      {:ok, task} =
        Pipeline.update_task(system_scope(), task.id, %{
          stage: :design,
          stage_state: :failed,
          error: "Design manifest canvasUrl must be an absolute https URL.",
          worktree_path: worktree_dir
        })

      {:ok, role_run} =
        Runs.create_role_run(%{
          task_id: task.id,
          role_id: designer_role.id,
          status: :finished,
          started_at: DateTime.utc_now()
        })

      # Manifest was modified during chat from older stamp, but is invalid
      assert {:ok, %Task{stage_state: :failed, error: err}, %RoleRun{}} =
               Pipeline.settle_chat_turn(
                 task,
                 role_run,
                 %{exit_code: 0},
                 before_design_stamp: "old_stamp:100"
               )

      assert err =~ "absolute https URL"
      designs = Repo.all(from d in Design, where: d.task_id == ^task.id)
      assert Enum.empty?(designs)

      events = Repo.all(from e in RunEvent, where: e.role_run_id == ^role_run.id, order_by: [asc: e.seq])
      assert Enum.any?(events, fn e -> e.line =~ "[rail] Design manifest changed during chat, but was turned down" end)
    end
  end
end
