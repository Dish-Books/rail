defmodule Rail.Pipeline.Actions.SettleChatTurnTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.EngineerRunFinished
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
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

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
        backend_id: backend.id
      })

    {:ok, rev_role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 11007",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11007.",
        stage: :review,
        backend_id: backend.id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_settle_chat_11030",
      "identifier" => "TSK-11030",
      "title" => "Task 11030"
    })

    {:ok, issue_11030} = Issues.capture_issue(system_scope(), project, "Task 11030")

    {:ok, task} = Pipeline.create_task(issue_11030, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :review,
        stage_state: :awaiting_approval,
        worktree_path: repo_dir
      })

    %{
      backend: backend,
      workspace: workspace,
      project: project,
      eng_role: eng_role,
      rev_role: rev_role,
      task: task,
      repo_dir: repo_dir
    }
  end

  test "returns not_found when task or run does not exist" do
    assert {:error, :not_found} =
             Pipeline.settle_chat_turn("tsk_000000000000000000000000", "rr_000000000000000000000000")
  end

  test "settles clean chat turn, clears active_chat_role_id and pending_chat, and accumulates chat_usage", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    initial_usage = %TaskUsage{input_tokens: 50, output_tokens: 25, total_cost: Decimal.new("0.01")}

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev-1",
        pending_chat: "Can you clarify finding 1?",
        chat_fingerprint_head_sha: "head123",
        chat_fingerprint_dirty_digest: "digest123",
        chat_usage: initial_usage
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: rev_role_id}) |> Repo.update()

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run_id,
        task_id: task_id,
        is_chat: true,
        stream_path: "/tmp/settle_chat_turn/#{run_id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    turn_usage = %TaskUsage{input_tokens: 100, output_tokens: 50, total_cost: Decimal.new("0.05")}

    outcome = %{
      exit_code: 0,
      error: nil,
      usage: turn_usage,
      os_process: os_process
    }

    assert {:ok, %Task{active_chat_role_id: nil}, %Run{pending_chat: nil, chat_usage: %TaskUsage{}}} =
             Pipeline.settle_chat_turn(task.id, run_id, outcome)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_settled}}

    refreshed_task = Repo.get!(Task, task_id)
    refreshed_run = Repo.get!(Run, run_id)

    assert %Task{
             stage: :review,
             stage_state: :awaiting_approval,
             active_chat_role_id: nil,
             error: nil
           } = refreshed_task

    assert %Run{
             status: :finished,
             pending_chat: nil,
             chat_fingerprint_head_sha: nil,
             chat_fingerprint_dirty_digest: nil,
             chat_usage: %TaskUsage{input_tokens: 150, output_tokens: 75}
           } = refreshed_run

    refreshed_os_process = Repo.get!(OsProcess, os_process.id)
    assert refreshed_os_process.status == :finished
  end

  test "review chat returning a VERDICT line does not advance the stage", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-verdict"
      })

    Runs.append_run_event(run_id, "Reviewed.\n\nVERDICT: APPROVED")

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: rev_role_id}) |> Repo.update()

    outcome = %{
      exit_code: 0,
      error: nil,
      usage: %TaskUsage{input_tokens: 20, output_tokens: 10}
    }

    assert {:ok, %Task{stage: :review, stage_state: :awaiting_approval}, %Run{}} =
             Pipeline.settle_chat_turn(task, run_id, outcome)

    Runs.append_run_event(run_id, "I still have concerns.\n\nVERDICT: CHANGES REQUESTED")

    refreshed_task = Repo.get!(Task, task_id)

    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :awaiting_approval
  end

  test "chat turn emitting [QUESTION:] does not file question or block stage", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
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
      usage: %TaskUsage{input_tokens: 30, output_tokens: 15}
    }

    assert {:ok, %Task{stage_state: :awaiting_approval}, %Run{}} =
             Pipeline.settle_chat_turn(task, run_id, outcome)

    questions = Repo.all(from q in Question, where: q.task_id == ^task_id)
    assert questions == []
  end

  test "engineer modifying files resets to engineer awaiting_approval (first pass)", %{
    task: %Task{id: task_id} = task,
    eng_role: %Role{id: eng_role_id},
    repo_dir: repo_dir
  } do
    before_fp = Rail.Git.branch_fingerprint(repo_dir)

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
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
      usage: %TaskUsage{input_tokens: 100, output_tokens: 50}
    }

    assert {:ok, %Task{stage: :engineer, stage_state: :awaiting_approval}, %Run{}} =
             Pipeline.settle_chat_turn(task, run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :engineer
    assert refreshed_task.stage_state == :awaiting_approval

    events = Runs.list_run_events(run_id)

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

    {:ok, %Run{id: eng_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng-rework",
        chat_fingerprint_head_sha: before_fp.head_sha,
        chat_fingerprint_dirty_digest: before_fp.dirty_digest
      })

    {:ok, %Run{id: rev_run_id}} =
      Runs.create_run(%{
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
      usage: %TaskUsage{input_tokens: 120, output_tokens: 60}
    }

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %Run{}} =
             Pipeline.settle_chat_turn(task, eng_run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :queued
    assert refreshed_task.outstanding_reports == []

    eng_events = Runs.list_run_events(eng_run_id)

    assert Enum.any?(eng_events, fn %RunEvent{line: line} ->
             line == "[rail] Branch modified during chat; queued for review."
           end)

    refreshed_rev = Repo.get!(Run, rev_run_id)
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

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
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
      usage: %TaskUsage{input_tokens: 40, output_tokens: 20}
    }

    assert {:ok, %Task{stage: :review, stage_state: :awaiting_approval}, %Run{}} =
             Pipeline.settle_chat_turn(task, run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :awaiting_approval

    events = Runs.list_run_events(run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line == "[rail] Changes were made to the branch, but only Engineer changes reset the pipeline."
           end)
  end

  test "failed chat exit logs notice and does not fail task stage", %{
    task: %Task{id: task_id} = task,
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
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
      error: "Command failed: exit 1"
    }

    assert {:ok, %Task{stage: :review, stage_state: :awaiting_approval}, %Run{}} =
             Pipeline.settle_chat_turn(task, run_id, outcome)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.stage == :review
    assert refreshed_task.stage_state == :awaiting_approval
    assert refreshed_task.active_chat_role_id == nil
    assert refreshed_task.error == nil

    events = Runs.list_run_events(run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line =~ "[rail] That turn was not delivered: Command failed: exit 1"
           end)
  end

  test "dispatches queued pending_chat when task becomes idle after settlement", %{
    backend: backend,
    task: %Task{id: task_id} = task,
    eng_role: %Role{id: eng_role_id},
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, _backend} =
      Rail.Backends.update_backend(system_scope(), backend, %{
        executable_path: create_chat_stub_cli(conversation_id: "sess-rev-queued")
      })

    {:ok, %Run{id: eng_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng-current"
      })

    {:ok, %Run{id: rev_run_id}} =
      Runs.create_run(%{
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
      usage: %TaskUsage{input_tokens: 10, output_tokens: 10}
    }

    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task, eng_run_id, outcome, async: false)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.active_chat_role_id == rev_role_id

    rev_runs = Runs.list_os_processes(run_id: rev_run_id)
    assert length(rev_runs) == 1
    assert hd(rev_runs).is_chat
  end

  test "settling a stage run dispatches queued pending_chat when the task goes idle", %{
    backend: backend,
    task: %Task{id: task_id} = task,
    eng_role: %Role{id: eng_role_id},
    rev_role: %Role{id: rev_role_id}
  } do
    {:ok, _backend} =
      Rail.Backends.update_backend(system_scope(), backend, %{
        executable_path: create_chat_stub_cli(conversation_id: "sess-rev-stage-finish")
      })

    {:ok, %Run{id: eng_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng-stage"
      })

    {:ok, %Run{id: rev_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev-stage-finish",
        pending_chat: "Queued question while stage was running"
      })

    {:ok, _task} =
      task
      |> Task.changeset(%{stage: :engineer, stage_state: :running})
      |> Repo.update()

    stage_run =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: eng_run_id,
        task_id: task_id,
        stream_path: "/tmp/settle_chat_turn/#{eng_run_id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    outcome = %{
      exit_code: 0,
      error: nil,
      usage: %TaskUsage{input_tokens: 500, output_tokens: 200},
      os_process: stage_run
    }

    {:ok, _settled, _settled_rr} = Pipeline.settle_run(stage_run, outcome, async: false)

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %Run{}} =
             finish_engineer_run(stage_run, %{}, async: false)

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.active_chat_role_id == rev_role_id

    rev_runs = Runs.list_os_processes(run_id: rev_run_id)
    assert length(rev_runs) == 1
    assert hd(rev_runs).is_chat
  end

  test "settle_chat_turn when branch modified and no review run exists creates new review run", %{
    task: task,
    eng_role: eng_role
  } do
    {:ok, %Run{id: eng_run_id}} =
      Runs.create_run(%{
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

    assert {:ok, %Task{stage: :review, stage_state: :queued}, %Run{}} =
             Pipeline.settle_chat_turn(task, eng_run_id, %{exit_code: 0})
  end

  test "settle_chat_turn when branch modified and project has no review role", %{
    backend: backend,
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

    {:ok, task_no_rev} = Pipeline.create_task(issue_11031, :product)

    {:ok, task_no_rev} =
      Pipeline.update_task(task_no_rev, %{
        stage: :review,
        stage_state: :queued,
        worktree_path: orig_task.worktree_path,
        rework_cycles: 1
      })

    {:ok, eng_role_no_rev} =
      Roles.create_role(system_scope(), proj_no_rev, %{
        backend_id: backend.id,
        name: "Role 11008",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11008.",
        stage: :engineer
      })

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_no_rev.id,
        role_id: eng_role_no_rev.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        chat_fingerprint_head_sha: "head_before_456",
        chat_fingerprint_dirty_digest: "digest_before_456"
      })

    File.write!(Path.join(task_no_rev.worktree_path, "no_rev.txt"), "data\n")

    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task_no_rev, run, %{exit_code: 0})
  end

  test "settle_chat_turn resolves string-keyed maps, raw maps, and finishes in-flight run", %{
    task: task,
    eng_role: eng_role
  } do
    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: eng_role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        exit_code: 42,
        error: "run error"
      })

    in_flight_run =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        is_chat: true,
        stream_path: "/tmp/settle_chat_turn/#{run.id}.ndjson",
        node: to_string(Node.self()),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    # Finishing in_flight_run when passed as %OsProcess{}
    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task.id, run.id, in_flight_run)

    assert Repo.get!(OsProcess, in_flight_run.id).status == :finished

    # String-keyed exit_code, error, usage map
    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task.id, run.id, %{
               "exit_code" => 0,
               "error" => "ignored error",
               "usage" => %{"input_tokens" => 20, "output_tokens" => 10}
             })

    # Map usage under :usage
    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task.id, run.id, %{
               exit_code: 0,
               usage: %{input_tokens: 15, output_tokens: 5}
             })

    # %TaskUsage{} under "usage"
    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task.id, run.id, %{
               "usage" => %TaskUsage{input_tokens: 10, output_tokens: 5}
             })

    # Fallback to run exit code and error
    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task, run)

    # Fallback exit code 0 when neither outcome nor run has integer exit code
    {:ok, run_nil_code} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: eng_role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        exit_code: nil
      })

    assert {:ok, %Task{}, %Run{}} =
             Pipeline.settle_chat_turn(task, run_nil_code, %{exit_code: nil})

    # Invalid targets return :not_found
    assert {:error, :not_found} = Pipeline.settle_chat_turn(12_345, run)
    assert {:error, :not_found} = Pipeline.settle_chat_turn(task, 12_345)
  end

  describe "settle_chat_turn at design stage" do
    test "a chat turn that rewrites the manifest lands the design", %{
      backend: backend,
      project: _project,
      task: task,
      workspace: workspace
    } do
      {:ok, project} =
        Projects.create_project(system_scope(), %{
          linear_workspace_id: workspace.id,
          name: "Settle Chat Project 11004",
          github_repo: "org/settle-chat-11004",
          github_installation_id: 11_004,
          linear_team_id: "team_settle_chat_11004",
          linear_team_key: "P11004",
          default_branch: "main",
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
          backend_id: backend.id,
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

      stub(File, :read, fn _path -> {:ok, design_manifest} end)
      stub(File, :exists?, fn _path -> true end)
      stub(File, :stat, fn _path -> {:ok, %File.Stat{type: :regular, size: 128}} end)

      {:ok, task} =
        Pipeline.update_task(task, %{
          stage: :design,
          stage_state: :failed,
          error: "Initial canvas 404",
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: designer_role.id,
          status: :finished,
          started_at: DateTime.utc_now()
        })

      mock_design_uploads(2)

      assert {:ok, %Task{stage_state: :awaiting_approval, error: nil}, %Run{}} =
               Pipeline.settle_chat_turn(
                 task,
                 run,
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
      backend: backend,
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
          default_branch: "main",
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
          backend_id: backend.id,
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

      stub(File, :read, fn _path -> {:ok, design_manifest} end)
      stub(File, :exists?, fn _path -> true end)

      {:ok, task} =
        Pipeline.update_task(task, %{
          stage: :design,
          stage_state: :failed,
          error: "Design manifest canvasUrl must be an absolute https URL.",
          worktree_path: worktree_dir,
          scratch_path: worktree_dir
        })

      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: designer_role.id,
          status: :finished,
          started_at: DateTime.utc_now()
        })

      # Manifest was modified during chat from older stamp, but is invalid
      assert {:ok, %Task{stage_state: :failed, error: err}, %Run{}} =
               Pipeline.settle_chat_turn(
                 task,
                 run,
                 %{exit_code: 0},
                 before_design_stamp: "old_stamp:100"
               )

      assert err =~ "absolute https URL"
      designs = Repo.all(from d in Design, where: d.task_id == ^task.id)
      assert Enum.empty?(designs)

      events = Repo.all(from e in RunEvent, where: e.run_id == ^run.id, order_by: [asc: e.seq])
      assert Enum.any?(events, fn e -> e.line =~ "[rail] Design manifest changed during chat, but was turned down" end)
    end
  end
end
