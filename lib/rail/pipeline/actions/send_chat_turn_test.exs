defmodule Rail.Pipeline.Actions.SendChatTurnTest do
  use Rail.DataCase, async: true

  import RailTest.PipelineHelpers

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Scope
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Send Chat Workspace",
        external_id: "lin_ws_send_chat",
        token: "lin_api_token_send_chat",
        webhook_secret: "whsec_send_chat"
      })

    repo_dir = create_temp_git_repo()

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        linear_workspace_id: workspace.id,
        name: "Send Chat Project 11202",
        github_repo: "org/send-chat-11202",
        github_installation_id: 11_202,
        linear_team_id: "team_send_chat_11202",
        linear_team_key: "P11202",
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

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 11204",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11204.",
        stage: :engineer,
        cli_backend: :claude
      })

    {:ok, reviewer_role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 11205",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11205.",
        stage: :review,
        cli_backend: :claude
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_chat_11227",
      "identifier" => "TSK-11227",
      "title" => "Task 11227"
    })

    {:ok, issue_11227} = Issues.capture_issue(system_scope(), project, "Task 11227")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_send_chat_11227"})

    {:ok, task} = Pipeline.create_task(issue_11227)

    {:ok, task} =
      Pipeline.update_task(system_scope(), task.id, %{
        stage: :engineer,
        stage_state: :queued,
        worktree_path: repo_dir
      })

    stub_bin = create_chat_stub_cli(conversation_id: "sess-chat-1")

    %{
      workspace: workspace,
      project: project,
      role: role,
      reviewer_role: reviewer_role,
      task: task,
      repo_dir: repo_dir,
      stub_bin: stub_bin
    }
  end

  test "returns not_authorized for invalid scope", %{task: task, role: role} do
    assert {:error, :not_authorized} =
             Pipeline.send_chat_turn(%Scope{system: false, user: nil}, task.id, role.id, "Hello")
  end

  test "returns not_found when task does not exist", %{role: role} do
    assert {:error, :not_found} =
             Pipeline.send_chat_turn("tsk_000000000000000000000000", role.id, "Hello")
  end

  test "returns role_not_found when role does not exist", %{task: task} do
    assert {:error, {:role_not_found, "rol_nonexistent"}} =
             Pipeline.send_chat_turn(task.id, "rol_nonexistent", "Hello")
  end

  test "returns chat_unavailable when role run has not started or has no conversation_id", %{
    task: task,
    role: role
  } do
    assert {:error, :chat_unavailable} =
             Pipeline.send_chat_turn(task.id, role.id, "Hello")

    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 0,
        conversation_id: nil
      })

    assert {:error, :chat_unavailable} =
             Pipeline.send_chat_turn(task.id, role.id, "Hello")
  end

  test "returns empty_message when text is blank", %{task: task, role: role} do
    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-1"
      })

    assert {:error, :empty_message} = Pipeline.send_chat_turn(task.id, role.id, "   ")
    assert {:error, :empty_message} = Pipeline.send_chat_turn(task.id, role.id, nil)
  end

  test "returns invalid_delivery_mode for unsupported mode", %{task: task, role: role} do
    {:ok, _role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-1"
      })

    assert {:error, {:invalid_delivery_mode, :invalid}} =
             Pipeline.send_chat_turn(task.id, role.id, "Hello", delivery: :invalid)
  end

  test "delivers chat turn immediately when idle, creates Run kind: :chat, and leaves stage intact", %{
    task: %Task{id: task_id},
    role: %Role{id: role_id},
    stub_bin: stub_bin
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-chat-1",
        output: "Original stage output"
      })

    assert {:ok, :sent, %Task{active_chat_role_id: ^role_id, stage: :engineer, stage_state: :queued}} =
             Pipeline.send_chat_turn(
               task_id,
               role_id,
               "Line 1\nLine 2",
               executable: stub_bin,
               async: false
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_dispatched}}

    events = Runs.list_run_events(role_run_id)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Line 1" end)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Line 2" end)

    runs = Runs.list_runs(task_id: task_id)

    assert [
             %Run{
               kind: :chat,
               status: :running,
               role_run_id: ^role_run_id
             }
           ] = runs

    refreshed_task = Repo.get!(Task, task_id)
    refreshed_role_run = Repo.get!(RoleRun, role_run_id)

    assert %Task{
             stage: :engineer,
             stage_state: :queued,
             active_chat_role_id: ^role_id,
             error: nil
           } = refreshed_task

    assert %RoleRun{
             status: :finished,
             output: "Original stage output",
             chat_fingerprint_head_sha: head_sha,
             chat_fingerprint_dirty_digest: dirty_digest
           } = refreshed_role_run

    assert is_binary(head_sha) and is_binary(dirty_digest)
  end

  test "sendChatTurn with when_finished holds message on busy task and appends pending_chat", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-busy"
      })

    {:ok, task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    assert {:ok, :queued, %Task{id: ^task_id}} =
             Pipeline.send_chat_turn(
               task.id,
               role_id,
               "Hold this thought",
               delivery: :when_finished
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_queued}}

    assert %RoleRun{pending_chat: "Hold this thought"} = Repo.get!(RoleRun, role_run_id)

    assert {:ok, :queued, %Task{id: ^task_id}} =
             Pipeline.send_chat_turn(
               task.id,
               role_id,
               "Second thought",
               delivery: :when_finished
             )

    assert %RoleRun{pending_chat: "Hold this thought\n\nSecond thought"} =
             Repo.get!(RoleRun, role_run_id)

    events = Runs.list_run_events(role_run_id)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Hold this thought" end)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Second thought" end)
  end

  test "sendChatTurn with immediate holds message when task is already busy", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-immediate-busy"
      })

    {:ok, _task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    assert {:ok, :queued, %Task{id: ^task_id}} =
             Pipeline.send_chat_turn(task_id, role_id, "Immediate but busy", delivery: :immediate)

    assert %RoleRun{pending_chat: "Immediate but busy"} = Repo.get!(RoleRun, role_run_id)
  end

  test "stop_and_send during stage run for different role stops run and dispatches chat first", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: eng_role_id},
    reviewer_role: %Role{id: rev_role_id},
    stub_bin: stub_bin
  } do
    {:ok, %RoleRun{id: eng_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng"
      })

    {:ok, %RoleRun{id: rev_role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev"
      })

    {:ok, task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    assert {:ok, :sent, %Task{active_chat_role_id: ^rev_role_id}} =
             Pipeline.send_chat_turn(
               task.id,
               rev_role_id,
               "Reviewer urgent question",
               delivery: :stop_and_send,
               executable: stub_bin,
               async: false
             )

    eng_events = Runs.list_run_events(eng_role_run_id)

    assert Enum.any?(eng_events, fn %RunEvent{line: line} ->
             line =~ "Run stopped by user to send chat to"
           end)

    rev_events = Runs.list_run_events(rev_role_run_id)

    assert Enum.any?(rev_events, fn %RunEvent{line: line} ->
             line == "[human] Reviewer urgent question"
           end)
  end

  test "stop_and_send while chat to role A is running clears role A pendingChat and runs role B", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_a_id},
    reviewer_role: %Role{id: role_b_id},
    stub_bin: stub_bin
  } do
    {:ok, %RoleRun{id: role_a_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_a_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-a",
        pending_chat: "old pending for A"
      })

    {:ok, %RoleRun{id: role_b_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_b_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-b"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: role_a_id}) |> Repo.update()

    assert {:ok, :sent, %Task{active_chat_role_id: ^role_b_id}} =
             Pipeline.send_chat_turn(
               task.id,
               role_b_id,
               "Question for B",
               delivery: :stop_and_send,
               executable: stub_bin,
               async: false
             )

    role_a_events = Runs.list_run_events(role_a_run_id)

    assert Enum.any?(role_a_events, fn %RunEvent{line: line} ->
             line =~ "Chat turn stopped by user to send chat to"
           end)

    refreshed_a = Repo.get!(RoleRun, role_a_run_id)
    assert refreshed_a.pending_chat == nil

    role_b_events = Runs.list_run_events(role_b_run_id)

    assert Enum.any?(role_b_events, fn %RunEvent{line: line} ->
             line == "[human] Question for B"
           end)
  end

  test "stop_and_send while chat to role A is running keeps pendingChat and resends to role A", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_a_id},
    stub_bin: stub_bin
  } do
    {:ok, %RoleRun{id: role_a_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_a_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-a"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: role_a_id}) |> Repo.update()

    assert {:ok, :sent, %Task{active_chat_role_id: ^role_a_id}} =
             Pipeline.send_chat_turn(
               task.id,
               role_a_id,
               "Urgent correction for A",
               delivery: :stop_and_send,
               executable: stub_bin,
               async: false
             )

    role_a_events = Runs.list_run_events(role_a_run_id)

    assert Enum.any?(role_a_events, fn %RunEvent{line: line} ->
             line == "[rail] Chat turn stopped by user."
           end)

    assert Enum.any?(role_a_events, fn %RunEvent{line: line} ->
             line == "[human] Urgent correction for A"
           end)
  end

  test "handles worktree creation failure during chat turn", %{task: task, role: role, workspace: workspace} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %RoleRun{} = role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-wt-fail"
      })

    assert {:error, :project_not_found} =
             Pipeline.dispatch_chat_turn(
               %{task | project_id: "prj_000000000000000000000000"},
               role,
               role_run,
               async: false
             )

    bad_repo = Path.join(System.tmp_dir!(), "bad_clone_#{System.unique_integer([:positive])}")
    File.mkdir_p!(bad_repo)

    {:ok, bad_project} =
      Projects.create_project(system_scope(), %{
        linear_workspace_id: workspace.id,
        name: "Send Chat Project 11203",
        github_repo: "org/send-chat-11203",
        github_installation_id: 11_203,
        linear_team_id: "team_send_chat_11203",
        linear_team_key: "P11203",
        clone_path: bad_repo,
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, bad_role} =
      Roles.create_role(system_scope(), bad_project, %{
        name: "Role 11206",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11206.",
        stage: :engineer
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_send_chat_bad",
      "identifier" => "SDC-BAD",
      "title" => "Bad Worktree Task"
    })

    {:ok, bad_issue} = Issues.capture_issue(system_scope(), bad_project, "Bad Worktree Task")
    LinearMock.mock_update_issue_success(%{"id" => "lin_send_chat_bad"})
    {:ok, bad_task} = Pipeline.create_task(bad_issue)

    {:ok, %Task{id: bad_task_id} = bad_task} =
      Pipeline.update_task(system_scope(), bad_task.id, %{
        stage: :engineer,
        stage_state: :queued
      })

    {:ok, %RoleRun{id: bad_role_run_id}} =
      Runs.create_role_run(%{
        task_id: bad_task.id,
        role_id: bad_role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-bad-wt"
      })

    assert {:error, {:worktree_failed, _reason}} =
             Pipeline.send_chat_turn(bad_task.id, bad_role.id, "Will fail worktree", async: false)

    assert_receive {:pipeline_changed, %{task_id: ^bad_task_id, event: :chat_failed}}

    refreshed_bad_task = Repo.get!(Task, bad_task.id)
    assert refreshed_bad_task.active_chat_role_id == nil

    bad_events = Runs.list_run_events(bad_role_run_id)

    assert Enum.any?(bad_events, fn %RunEvent{line: line} ->
             line =~ "[rail] That turn was not delivered"
           end)
  end

  test "handles spawn failure during chat turn", %{task: %Task{id: task_id}, role: role} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-spawn-fail"
      })

    assert {:error, {:spawn_failed, _reason}} =
             Pipeline.send_chat_turn(
               task_id,
               role.id,
               "Missing binary",
               executable: "/nonexistent/binary",
               async: false
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_failed}}

    events = Runs.list_run_events(role_run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line =~ "[rail] That turn was not delivered"
           end)
  end

  test "async dispatch with default on_finished callback and user scope", %{
    task: %Task{id: task_id},
    role: %Role{id: role_id},
    stub_bin: stub_bin
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-async"
      })

    user_scope = %Scope{system: false, user: %{id: "usr_1"}}

    # Arity 5 with Scope and async: true (default)
    assert {:ok, :sent, %Task{id: ^task_id}} =
             Pipeline.send_chat_turn(
               user_scope,
               task_id,
               role_id,
               "Async message",
               executable: stub_bin
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_dispatched}}, 1_000
    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_settled}}, 2_000

    refreshed_task = Repo.get!(Task, task_id)
    assert refreshed_task.active_chat_role_id == nil

    events = Runs.list_run_events(role_run_id)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Async message" end)
  end

  test "invalid targets and missing worktree fingerprint handling", %{
    task: %Task{} = task,
    role: role,
    project: project
  } do
    assert {:error, :not_found} = Pipeline.send_chat_turn(12_345, role.id, "Hi")
    assert {:error, :role_not_found} = Pipeline.send_chat_turn(task.id, 12_345, "Hi")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-fp-none"
      })

    # Non-git worktree path produces {nil, nil} fingerprint
    non_git_dir = Path.join(System.tmp_dir!(), "non_git_#{System.unique_integer([:positive])}")
    File.mkdir_p!(non_git_dir)

    stub_bin = create_chat_stub_cli(conversation_id: "sess-fp-none")

    assert {:ok, :sent, %Task{}} =
             Pipeline.send_chat_turn(
               task.id,
               role.id,
               "Msg",
               worktree_path: non_git_dir,
               executable: stub_bin,
               async: false
             )

    # Arity 3 dispatch_chat_turn and Arity 1 maybe_dispatch_queued_pending_chat
    assert {:ok, %Task{}} = Pipeline.dispatch_chat_turn(task, role, role_run)
    assert :ok = Pipeline.maybe_dispatch_queued_pending_chat(task)

    # maybe_dispatch_queued_pending_chat when task is busy
    busy_task = %{task | stage_state: :running}
    assert :ok = Pipeline.maybe_dispatch_queued_pending_chat(busy_task)

    # maybe_dispatch_queued_pending_chat when role is missing in DB
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_chat_11228",
      "identifier" => "TSK-11228",
      "title" => "Task 11228"
    })

    {:ok, issue_11228} = Issues.capture_issue(system_scope(), project, "Task 11228")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_send_chat_11228"})

    {:ok, missing_role_task} = Pipeline.create_task(issue_11228)

    {:ok, missing_role_rr} =
      Runs.create_role_run(%{
        task_id: missing_role_task.id,
        role_id: "rol_000000000000000000000000",
        status: :finished,
        started_at: DateTime.utc_now(),
        pending_chat: "Orphan pending"
      })

    assert :ok = Pipeline.maybe_dispatch_queued_pending_chat(missing_role_task)
    Repo.delete!(missing_role_rr)
  end

  test "stop_and_send to same role during stage run, missing chat runs, and empty pending_chat", %{
    task: task,
    role: %Role{id: target_role_id} = role,
    stub_bin: stub_bin,
    project: project
  } do
    {:ok, %RoleRun{id: role_run_id}} =
      Runs.create_role_run(%{
        task_id: task.id,
        role_id: target_role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-same-stage",
        pending_chat: ""
      })

    # append_pending with empty string
    assert {:ok, :queued, %Task{}} =
             Pipeline.send_chat_turn(task, role, "Appended to empty", delivery: :when_finished)

    assert Repo.get!(RoleRun, role_run_id).pending_chat == "Appended to empty"

    {:ok, running_stage_task} =
      task
      |> Task.changeset(%{stage: :engineer, stage_state: :running})
      |> Repo.update()

    # stop_and_send to same role during stage run
    assert {:ok, :sent, %Task{active_chat_role_id: ^target_role_id}} =
             Pipeline.send_chat_turn(
               running_stage_task,
               role,
               "Restart with this instruction",
               delivery: :stop_and_send,
               executable: stub_bin,
               async: false
             )

    # Missing stopped role runs in DB
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_chat_11229",
      "identifier" => "TSK-11229",
      "title" => "Task 11229"
    })

    {:ok, issue_11229} = Issues.capture_issue(system_scope(), project, "Task 11229")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_send_chat_11229"})

    {:ok, orphan_same_task} = Pipeline.create_task(issue_11229)

    {:ok, orphan_same_task} =
      Pipeline.update_task(system_scope(), orphan_same_task.id, %{
        active_chat_role_id: role.id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_chat_11230",
      "identifier" => "TSK-11230",
      "title" => "Task 11230"
    })

    {:ok, issue_11230} = Issues.capture_issue(system_scope(), project, "Task 11230")

    LinearMock.mock_update_issue_success(%{"id" => "lin_task_send_chat_11230"})

    {:ok, orphan_other_task} = Pipeline.create_task(issue_11230)

    {:ok, orphan_other_task} =
      Pipeline.update_task(system_scope(), orphan_other_task.id, %{
        active_chat_role_id: "rol_other_missing"
      })

    # Creates role run for target so can_chat passes
    {:ok, _target_rr1} =
      Runs.create_role_run(%{
        task_id: orphan_same_task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-t1"
      })

    {:ok, _target_rr2} =
      Runs.create_role_run(%{
        task_id: orphan_other_task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-t2"
      })

    assert {:ok, :sent, %Task{}} =
             Pipeline.send_chat_turn(orphan_same_task, role, "Orphan same",
               delivery: :stop_and_send,
               executable: stub_bin,
               async: false
             )

    assert {:ok, :sent, %Task{}} =
             Pipeline.send_chat_turn(orphan_other_task, role, "Orphan other",
               delivery: :stop_and_send,
               executable: stub_bin,
               async: false
             )
  end
end
