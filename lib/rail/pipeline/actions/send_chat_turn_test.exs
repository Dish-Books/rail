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
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    stub_bin = create_chat_stub_cli(conversation_id: "sess-chat-1")

    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: stub_bin})

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
        backend_id: backend.id
      })

    {:ok, reviewer_role} =
      Roles.create_role(system_scope(), project, %{
        name: "Role 11205",
        model: "claude-3-7-sonnet",
        system_prompt: "You are an expert agent for role 11205.",
        stage: :review,
        backend_id: backend.id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_chat_11227",
      "identifier" => "TSK-11227",
      "title" => "Task 11227"
    })

    {:ok, issue_11227} = Issues.capture_issue(system_scope(), project, "Task 11227")

    {:ok, task} = Pipeline.create_task(issue_11227, :product)

    {:ok, task} =
      Pipeline.update_task(task, %{
        stage: :engineer,
        stage_state: :queued,
        worktree_path: repo_dir
      })

    %{
      backend: backend,
      workspace: workspace,
      project: project,
      role: role,
      reviewer_role: reviewer_role,
      task: task,
      repo_dir: repo_dir
    }
  end

  test "returns role_not_found when role does not exist", %{task: task} do
    assert {:error, {:role_not_found, "rol_nonexistent"}} =
             Pipeline.send_chat_turn(task, "rol_nonexistent", "Hello")
  end

  test "returns chat_unavailable when run has not started or has no conversation_id", %{
    task: task,
    role: role
  } do
    assert {:error, :chat_unavailable} =
             Pipeline.send_chat_turn(task, role.id, "Hello")

    {:ok, _run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 0,
        conversation_id: nil
      })

    assert {:error, :chat_unavailable} =
             Pipeline.send_chat_turn(task, role.id, "Hello")
  end

  test "returns empty_message when text is blank", %{task: task, role: role} do
    {:ok, _run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-1"
      })

    assert {:error, :empty_message} = Pipeline.send_chat_turn(task, role.id, "   ")
    assert {:error, :empty_message} = Pipeline.send_chat_turn(task, role.id, nil)
  end

  test "returns invalid_delivery_mode for unsupported mode", %{task: task, role: role} do
    {:ok, _run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-1"
      })

    assert {:error, {:invalid_delivery_mode, :invalid}} =
             Pipeline.send_chat_turn(task, role.id, "Hello", delivery: :invalid)
  end

  test "delivers chat turn immediately when idle, creates Run is_chat: true, and leaves stage intact", %{
    task: %Task{id: task_id},
    role: %Role{id: role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-chat-1"
      })

    test_pid = self()

    expect(Runs, :start_os_process, fn %Run{} = spawned, argv, opts ->
      send(test_pid, {:spawned, spawned.id, argv, opts})
      {:ok, %OsProcess{run_id: spawned.id, is_chat: opts[:is_chat], run: spawned, task: Repo.get!(Task, spawned.task_id)}}
    end)

    assert {:ok, :sent, %Task{active_chat_role_id: ^role_id, stage: :engineer, stage_state: :queued}} =
             Pipeline.send_chat_turn(
               Repo.get!(Task, task_id),
               role_id,
               "Line 1\nLine 2",
               async: false
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_dispatched}}

    events = Runs.list_run_events(run_id)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Line 1" end)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Line 2" end)

    assert_receive {:spawned, ^run_id, argv, opts}
    assert opts[:is_chat]
    assert Enum.any?(argv, &(&1 =~ "Line 1" and &1 =~ "Line 2"))

    refreshed_task = Repo.get!(Task, task_id)
    refreshed_run = Repo.get!(Run, run_id)

    assert %Task{
             stage: :engineer,
             stage_state: :queued,
             active_chat_role_id: ^role_id,
             error: nil
           } = refreshed_task

    assert %Run{
             status: :finished,
             chat_fingerprint_head_sha: head_sha,
             chat_fingerprint_dirty_digest: dirty_digest
           } = refreshed_run

    assert is_binary(head_sha) and is_binary(dirty_digest)
  end

  test "sendChatTurn with when_finished holds message on busy task and appends pending_chat", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
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
               task,
               role_id,
               "Hold this thought",
               delivery: :when_finished
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_queued}}

    assert %Run{pending_chat: "Hold this thought"} = Repo.get!(Run, run_id)

    assert {:ok, :queued, %Task{id: ^task_id}} =
             Pipeline.send_chat_turn(
               task,
               role_id,
               "Second thought",
               delivery: :when_finished
             )

    assert %Run{pending_chat: "Hold this thought\n\nSecond thought"} =
             Repo.get!(Run, run_id)

    events = Runs.list_run_events(run_id)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Hold this thought" end)
    assert Enum.any?(events, fn %RunEvent{line: line} -> line == "[human] Second thought" end)
  end

  test "sendChatTurn with immediate holds message when task is already busy", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_id}
  } do
    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-immediate-busy"
      })

    {:ok, _task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    assert {:ok, :queued, %Task{id: ^task_id}} =
             Pipeline.send_chat_turn(Repo.get!(Task, task_id), role_id, "Immediate but busy", delivery: :immediate)

    assert %Run{pending_chat: "Immediate but busy"} = Repo.get!(Run, run_id)
  end

  test "stop_and_send during stage run for different role stops run and dispatches chat first", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: eng_role_id},
    reviewer_role: %Role{id: rev_role_id}
  } do
    {:ok, %Run{id: eng_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: eng_role_id,
        status: :running,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-eng"
      })

    {:ok, %Run{id: rev_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: rev_role_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-rev"
      })

    {:ok, task} = task |> Task.changeset(%{stage_state: :running}) |> Repo.update()

    test_pid = self()

    expect(Runs, :start_os_process, fn %Run{} = spawned, argv, opts ->
      send(test_pid, {:spawned, spawned.id, argv, opts})
      {:ok, %OsProcess{run_id: spawned.id, is_chat: opts[:is_chat], run: spawned, task: Repo.get!(Task, spawned.task_id)}}
    end)

    assert {:ok, :sent, %Task{active_chat_role_id: ^rev_role_id}} =
             Pipeline.send_chat_turn(
               task,
               rev_role_id,
               "Reviewer urgent question",
               delivery: :stop_and_send,
               async: false
             )

    eng_events = Runs.list_run_events(eng_run_id)

    assert Enum.any?(eng_events, fn %RunEvent{line: line} ->
             line =~ "Run stopped by user to send chat to"
           end)

    rev_events = Runs.list_run_events(rev_run_id)

    assert Enum.any?(rev_events, fn %RunEvent{line: line} ->
             line == "[human] Reviewer urgent question"
           end)
  end

  test "stop_and_send while chat to role A is running clears role A pendingChat and runs role B", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_a_id},
    reviewer_role: %Role{id: role_b_id}
  } do
    {:ok, %Run{id: role_a_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_a_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-a",
        pending_chat: "old pending for A"
      })

    {:ok, %Run{id: role_b_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_b_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-b"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: role_a_id}) |> Repo.update()

    test_pid = self()

    expect(Runs, :start_os_process, fn %Run{} = spawned, argv, opts ->
      send(test_pid, {:spawned, spawned.id, argv, opts})
      {:ok, %OsProcess{run_id: spawned.id, is_chat: opts[:is_chat], run: spawned, task: Repo.get!(Task, spawned.task_id)}}
    end)

    assert {:ok, :sent, %Task{active_chat_role_id: ^role_b_id}} =
             Pipeline.send_chat_turn(
               task,
               role_b_id,
               "Question for B",
               delivery: :stop_and_send,
               async: false
             )

    role_a_events = Runs.list_run_events(role_a_run_id)

    assert Enum.any?(role_a_events, fn %RunEvent{line: line} ->
             line =~ "Chat turn stopped by user to send chat to"
           end)

    refreshed_a = Repo.get!(Run, role_a_run_id)
    assert refreshed_a.pending_chat == nil

    role_b_events = Runs.list_run_events(role_b_run_id)

    assert Enum.any?(role_b_events, fn %RunEvent{line: line} ->
             line == "[human] Question for B"
           end)
  end

  test "stop_and_send while chat to role A is running keeps pendingChat and resends to role A", %{
    task: %Task{id: task_id} = task,
    role: %Role{id: role_a_id}
  } do
    {:ok, %Run{id: role_a_run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_a_id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-a"
      })

    {:ok, task} = task |> Task.changeset(%{active_chat_role_id: role_a_id}) |> Repo.update()

    test_pid = self()

    expect(Runs, :start_os_process, fn %Run{} = spawned, argv, opts ->
      send(test_pid, {:spawned, spawned.id, argv, opts})
      {:ok, %OsProcess{run_id: spawned.id, is_chat: opts[:is_chat], run: spawned, task: Repo.get!(Task, spawned.task_id)}}
    end)

    assert {:ok, :sent, %Task{active_chat_role_id: ^role_a_id}} =
             Pipeline.send_chat_turn(
               task,
               role_a_id,
               "Urgent correction for A",
               delivery: :stop_and_send,
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

  test "handles worktree creation failure during chat turn", %{
    backend: backend,
    task: task,
    role: role,
    workspace: workspace
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Run{} = run} =
      Runs.create_run(%{
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
               run,
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
        default_branch: "main",
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
        backend_id: backend.id,
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
    {:ok, bad_task} = Pipeline.create_task(bad_issue, :product)

    {:ok, %Task{id: bad_task_id} = bad_task} =
      Pipeline.update_task(bad_task, %{
        stage: :engineer,
        stage_state: :queued
      })

    {:ok, %Run{id: bad_run_id}} =
      Runs.create_run(%{
        task_id: bad_task.id,
        role_id: bad_role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-bad-wt"
      })

    assert {:error, {:worktree_failed, _reason}} =
             Pipeline.send_chat_turn(bad_task, bad_role.id, "Will fail worktree", async: false)

    assert_receive {:pipeline_changed, %{task_id: ^bad_task_id, event: :chat_failed}}

    refreshed_bad_task = Repo.get!(Task, bad_task.id)
    assert refreshed_bad_task.active_chat_role_id == nil

    bad_events = Runs.list_run_events(bad_run_id)

    assert Enum.any?(bad_events, fn %RunEvent{line: line} ->
             line =~ "[rail] That turn was not delivered"
           end)
  end

  test "handles spawn failure during chat turn", %{backend: backend, task: %Task{id: task_id}, role: role} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")

    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        attempts: 1,
        conversation_id: "sess-spawn-fail"
      })

    {:ok, _backend} =
      Rail.Backends.update_backend(system_scope(), backend, %{executable_path: "/nonexistent/binary"})

    assert {:error, {:spawn_failed, _reason}} =
             Pipeline.send_chat_turn(
               Repo.get!(Task, task_id),
               role.id,
               "Missing binary",
               async: false
             )

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :chat_failed}}

    events = Runs.list_run_events(run_id)

    assert Enum.any?(events, fn %RunEvent{line: line} ->
             line =~ "[rail] That turn was not delivered"
           end)
  end

  test "invalid targets and missing worktree fingerprint handling", %{
    backend: backend,
    task: %Task{} = task,
    role: role,
    project: project
  } do
    assert {:error, :role_not_found} = Pipeline.send_chat_turn(task, 12_345, "Hi")

    {:ok, run} =
      Runs.create_run(%{
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

    {:ok, _backend} =
      Rail.Backends.update_backend(system_scope(), backend, %{
        executable_path: create_chat_stub_cli(conversation_id: "sess-fp-none")
      })

    assert {:ok, :sent, %Task{}} =
             Pipeline.send_chat_turn(
               task,
               role.id,
               "Msg",
               worktree_path: non_git_dir,
               async: false
             )

    # Arity 3 dispatch_chat_turn and Arity 1 maybe_dispatch_queued_pending_chat
    assert {:ok, %Task{}} = Pipeline.dispatch_chat_turn(task, role, run)
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

    {:ok, missing_role_task} = Pipeline.create_task(issue_11228, :product)

    {:ok, missing_role_rr} =
      Runs.create_run(%{
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
    project: project
  } do
    {:ok, %Run{id: run_id}} =
      Runs.create_run(%{
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

    assert Repo.get!(Run, run_id).pending_chat == "Appended to empty"

    {:ok, running_stage_task} =
      task
      |> Task.changeset(%{stage: :engineer, stage_state: :running})
      |> Repo.update()

    test_pid = self()

    expect(Runs, :start_os_process, 3, fn %Run{} = spawned, argv, opts ->
      send(test_pid, {:spawned, spawned.id, argv, opts})
      {:ok, %OsProcess{run_id: spawned.id, is_chat: opts[:is_chat], run: spawned, task: Repo.get!(Task, spawned.task_id)}}
    end)

    # stop_and_send to same role during stage run
    assert {:ok, :sent, %Task{active_chat_role_id: ^target_role_id}} =
             Pipeline.send_chat_turn(
               running_stage_task,
               role,
               "Restart with this instruction",
               delivery: :stop_and_send,
               async: false
             )

    # Missing stopped runs in DB
    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_chat_11229",
      "identifier" => "TSK-11229",
      "title" => "Task 11229"
    })

    {:ok, issue_11229} = Issues.capture_issue(system_scope(), project, "Task 11229")

    {:ok, orphan_same_task} = Pipeline.create_task(issue_11229, :product)

    {:ok, orphan_same_task} =
      Pipeline.update_task(orphan_same_task, %{
        active_chat_role_id: role.id
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_task_send_chat_11230",
      "identifier" => "TSK-11230",
      "title" => "Task 11230"
    })

    {:ok, issue_11230} = Issues.capture_issue(system_scope(), project, "Task 11230")

    {:ok, orphan_other_task} = Pipeline.create_task(issue_11230, :product)

    {:ok, orphan_other_task} =
      Pipeline.update_task(orphan_other_task, %{
        active_chat_role_id: "rol_other_missing"
      })

    # Creates run for target so can_chat passes
    {:ok, _target_rr1} =
      Runs.create_run(%{
        task_id: orphan_same_task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-t1"
      })

    {:ok, _target_rr2} =
      Runs.create_run(%{
        task_id: orphan_other_task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now(),
        conversation_id: "sess-t2"
      })

    assert {:ok, :sent, %Task{}} =
             Pipeline.send_chat_turn(orphan_same_task, role, "Orphan same",
               delivery: :stop_and_send,
               async: false
             )

    assert {:ok, :sent, %Task{}} =
             Pipeline.send_chat_turn(orphan_other_task, role, "Orphan other",
               delivery: :stop_and_send,
               async: false
             )
  end
end
