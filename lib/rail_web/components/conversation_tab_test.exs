defmodule RailWeb.Components.ConversationTabTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Domain.ChatTranscript
  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun
  alias RailWeb.Components.ConversationTab
  alias RailWeb.CoreComponents

  test "renders empty state when no roles have run the task" do
    task = %Task{id: "tsk_empty", stage: :product}

    html =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [],
        selected_run: nil,
        selected_role_id: nil,
        selected_role: nil
      )

    assert html =~ ~s(data-qa="conversation_empty_state")
    assert html =~ "No role has run this task yet."
  end

  test "renders role selector chips and metadata row for selected run" do
    task = %Task{id: "tsk_123", stage: :engineer}

    run1 = %RoleRun{
      id: "rr_1",
      role_id: "architect",
      status: :completed,
      started_at: ~U[2026-09-09 10:00:00Z],
      completed_at: ~U[2026-09-09 10:02:00Z],
      attempts: 2,
      conversation_id: "conv_arch_1",
      usage: %TaskUsage{input_tokens: 1000, output_tokens: 500}
    }

    run2 = %RoleRun{
      id: "rr_2",
      role_id: "engineer",
      status: :running,
      started_at: ~U[2026-09-09 10:05:00Z],
      attempts: 1,
      conversation_id: "conv_eng_2",
      chat_usage: %TaskUsage{input_tokens: 200, output_tokens: 100}
    }

    role1 = %Role{id: "architect", name: "Architect", icon_name: "architecture"}
    role2 = %Role{id: "engineer", name: "Engineer", icon_name: "code"}
    roles_map = %{"architect" => role1, "engineer" => role2}

    html =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [run1, run2],
        selected_run: run1,
        selected_role_id: "architect",
        selected_role: role1,
        roles_map: roles_map,
        show_raw_log: false
      )

    # Role selector row
    assert html =~ ~s(data-qa="role-selector-row")
    assert html =~ ~s(data-qa="role-chip-architect")
    assert html =~ "Architect"
    assert html =~ ~s(data-qa="role-chip-engineer")
    assert html =~ "Engineer"
    assert html =~ ~s(data-qa="toggle-raw-log")
    assert html =~ "Raw log"

    # Metadata row for run 1
    assert html =~ ~s(data-qa="run-metadata-row")
    assert html =~ "completed"
    assert html =~ ~s(data-qa="elapsed-text")
    assert html =~ "2 passes"
    assert html =~ "1.5K tokens"
    assert html =~ "conversation conv_arch_1"
  end

  test "renders toggle button as Show chat when raw log is active" do
    task = %Task{id: "tsk_123", stage: :engineer}
    run = %RoleRun{id: "rr_1", role_id: "engineer", status: :running, started_at: ~U[2026-09-09 10:00:00Z]}
    role = %Role{id: "engineer", name: "Engineer", icon_name: "code"}

    html =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [run],
        selected_run: run,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: %{"engineer" => role},
        show_raw_log: true
      )

    assert html =~ ~s(data-qa="toggle-raw-log")
    assert html =~ "Show chat"
    assert html =~ ~s(data-qa="raw_log_container")
  end

  test "renders ChatPane messages by kind: human, role, activity, handoff, and axis events" do
    task = %Task{id: "tsk_456", stage: :engineer}

    run = %RoleRun{
      id: "rr_eng",
      role_id: "engineer",
      status: :running,
      started_at: ~U[2026-09-09 10:00:00Z],
      conversation_id: "conv_live"
    }

    arch_run = %RoleRun{
      id: "rr_arch",
      role_id: "architect",
      status: :completed,
      started_at: ~U[2026-09-09 09:00:00Z]
    }

    role = %Role{id: "engineer", name: "Engineer", icon_name: "code"}
    roles_map = %{"engineer" => role, "architect" => %Role{id: "architect", name: "Architect", icon_name: "architecture"}}

    raw_logs = [
      "[human] Please implement the OAuth callback handler",
      "[run] Runner started execution",
      "I will start by reviewing the router.",
      "[tool read_file] lib/rail_web/router.ex",
      "[tool read_file] lib/rail_web/user_auth.ex",
      "[handoff ← architect] Ready for engineer implementation",
      "Follow the schema plan closely.",
      "[axis] Automated check completed"
    ]

    transcript = ChatTranscript.parse(raw_logs)

    # Render with activity collapsed
    html_collapsed =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [arch_run, run],
        selected_run: run,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: roles_map,
        transcript: transcript,
        expanded_activities: MapSet.new(),
        show_raw_log: false
      )

    # Human bubble
    assert html_collapsed =~ ~s(data-qa="human-bubble")
    assert html_collapsed =~ "Please implement the OAuth callback handler"
    assert html_collapsed =~ "You"

    # Role bubble
    assert html_collapsed =~ ~s(data-qa="role-bubble")
    assert html_collapsed =~ "I will start by reviewing the router."
    assert html_collapsed =~ "Engineer"

    # Activity tile collapsed (2 steps coalesced)
    assert html_collapsed =~ ~s(data-qa="activity-tile")
    assert html_collapsed =~ "Tool activity (2 steps)"
    refute html_collapsed =~ ~s(data-qa="activity-content")

    # Handoff tile
    assert html_collapsed =~ ~s(data-qa="handoff-tile")
    assert html_collapsed =~ "Ready for engineer implementation"
    assert html_collapsed =~ "Follow the schema plan closely."
    assert html_collapsed =~ ~s(data-qa="open-role-conversation")
    assert html_collapsed =~ "Open Architect conversation"

    # Axis event & system event
    assert html_collapsed =~ ~s(data-qa="axis-event")
    assert html_collapsed =~ "[axis] Automated check completed"
    assert html_collapsed =~ ~s(data-qa="system-event")
    assert html_collapsed =~ "[run] Runner started execution"

    # Render with activity expanded
    html_expanded =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [arch_run, run],
        selected_run: run,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: roles_map,
        transcript: transcript,
        expanded_activities: MapSet.new([3]),
        show_raw_log: false
      )

    assert html_expanded =~ ~s(data-qa="activity-content")
    assert html_expanded =~ "lib/rail_web/router.ex"
  end

  test "renders ChatPane empty state for pruned vs unpruned runs" do
    task = %Task{id: "tsk_empty", stage: :engineer}
    role = %Role{id: "engineer", name: "Engineer", icon_name: "code"}
    unpruned_run = %RoleRun{id: "rr_unpruned", role_id: "engineer", status: :running, pruned: false}

    html_unpruned =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [unpruned_run],
        selected_run: unpruned_run,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: %{"engineer" => role},
        transcript: %ChatTranscript{messages: []},
        show_raw_log: false
      )

    assert html_unpruned =~ "No messages yet."

    pruned_run = %RoleRun{id: "rr_pruned", role_id: "engineer", status: :completed, pruned: true}

    html_pruned =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [pruned_run],
        selected_run: pruned_run,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: %{"engineer" => role},
        transcript: %ChatTranscript{messages: []},
        show_raw_log: false
      )

    assert html_pruned =~ "This transcript aged out and was swept."
  end

  test "renders Composer banners in precedence: thinking > queued > unavailable" do
    role = %Role{id: "engineer", name: "Engineer", icon_name: "code"}

    # 1. Thinking banner
    task_thinking = %Task{id: "tsk_think", active_chat_role_id: "engineer"}

    run_live = %RoleRun{
      id: "rr_live",
      role_id: "engineer",
      status: :running,
      started_at: ~U[2026-09-09 10:00:00Z],
      conversation_id: "sess_1"
    }

    html_thinking =
      render_component(&ConversationTab.conversation_tab/1,
        task: task_thinking,
        ordered_runs: [run_live],
        selected_run: run_live,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: %{"engineer" => role}
      )

    assert html_thinking =~ ~s(data-qa="thinking-banner")
    assert html_thinking =~ "Engineer is thinking..."
    assert html_thinking =~ ~s(data-qa="stop-chat-turn")
    refute html_thinking =~ ~s(data-qa="queued-banner")
    refute html_thinking =~ ~s(data-qa="unavailable-banner")

    # 2. Queued banner
    task_idle = %Task{id: "tsk_queued", active_chat_role_id: nil}

    run_queued = %RoleRun{
      id: "rr_queued",
      role_id: "engineer",
      status: :completed,
      started_at: ~U[2026-09-09 10:00:00Z],
      conversation_id: "sess_2",
      pending_chat: "Check test coverage"
    }

    html_queued =
      render_component(&ConversationTab.conversation_tab/1,
        task: task_idle,
        ordered_runs: [run_queued],
        selected_run: run_queued,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: %{"engineer" => role}
      )

    assert html_queued =~ ~s(data-qa="queued-banner")
    assert html_queued =~ "Queued message: &quot;Check test coverage&quot; (delivers when pipeline pauses)"
    assert html_queued =~ ~s(data-qa="cancel-pending-chat")

    # 3. Unavailable banner (no conversation ID)
    run_unstarted = %RoleRun{
      id: "rr_new",
      role_id: "engineer",
      status: :running,
      started_at: nil,
      attempts: 0,
      conversation_id: nil
    }

    html_unavail =
      render_component(&ConversationTab.conversation_tab/1,
        task: task_idle,
        ordered_runs: [run_unstarted],
        selected_run: run_unstarted,
        selected_role_id: "engineer",
        selected_role: role,
        roles_map: %{"engineer" => role}
      )

    assert html_unavail =~ ~s(data-qa="unavailable-banner")
    assert html_unavail =~ "Cannot chat with Engineer yet: the role has not started a conversation."
    assert html_unavail =~ "Chat unavailable"
  end

  test "renders delivery modal when run is in flight" do
    modal = %{
      text: "Can you fix the unit tests?",
      role_id: "engineer",
      role_name: "Engineer"
    }

    html = render_component(&ConversationTab.delivery_modal/1, modal: modal)

    assert html =~ ~s(data-qa="delivery-modal")
    assert html =~ "A run is in flight"
    assert html =~ "The pipeline is currently executing a run. How would you like to deliver your message to Engineer?"
    assert html =~ ~s(data-qa="delivery-cancel")
    assert html =~ ~s(data-qa="delivery-when-finished")
    assert html =~ ~s(data-qa="delivery-stop-and-send")
  end

  test "renders Raw Log view with color classes and handoff button" do
    run = %RoleRun{id: "rr_log", role_id: "engineer", status: :completed}
    arch_run = %RoleRun{id: "rr_arch", role_id: "architect", status: :completed}
    roles_map = %{"architect" => %Role{id: "architect", name: "Architect", icon_name: "architecture"}}

    lines = [
      "[error] something failed",
      "[tool bash] mix test",
      "[human] please retry",
      "[axis] pipeline healthy",
      "[handoff → architect] Handoff back to architect",
      "normal debug line"
    ]

    html =
      render_component(&ConversationTab.raw_log_view/1,
        run: run,
        log_lines: lines,
        runs: [run, arch_run],
        roles_map: roles_map
      )

    assert html =~ ~s(data-qa="raw_log_container")
    assert html =~ "text-red-400"
    assert html =~ "[error] something failed"
    assert html =~ "text-cyan-300"
    assert html =~ "[tool bash] mix test"
    assert html =~ "text-amber-300"
    assert html =~ "[human] please retry"
    assert html =~ "text-green-400"
    assert html =~ "[axis] pipeline healthy"
    assert html =~ ~s(data-qa="raw-log-handoff")
    assert html =~ ~s(data-qa="open-role-log")
    assert html =~ "Open Architect log"
    assert html =~ "text-zinc-300"
    assert html =~ "normal debug line"
  end

  test "renders run metadata with chat_usage and single step tool activity" do
    task = %Task{id: "tsk_single_step", stage: :engineer}

    chat_usage = %TaskUsage{
      input_tokens: 250,
      output_tokens: 120
    }

    run = %RoleRun{
      id: "rr_chat",
      role_id: :engineer,
      status: :completed,
      started_at: ~U[2026-09-09 10:00:00Z],
      completed_at: ~U[2026-09-09 10:05:00Z],
      chat_usage: chat_usage,
      usage: "not_a_struct"
    }

    raw_logs = [
      "[tool read_file] config.ex"
    ]

    transcript = ChatTranscript.parse(raw_logs)

    # Test with expanded_activities as a list and nil roles_map
    html =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [run],
        selected_run: run,
        selected_role_id: :engineer,
        selected_role: nil,
        roles_map: nil,
        transcript: transcript,
        expanded_activities: [0],
        show_raw_log: false
      )

    assert html =~ ~s(id="metadata-run-chat-usage")
    assert html =~ "Chat:"
    assert html =~ "Tool activity (1 step)"
    assert html =~ "config.ex"

    # Test with unmapped role_id, invalid role id type, and nil expanded_activities
    html_fallbacks =
      render_component(&ConversationTab.conversation_tab/1,
        task: task,
        ordered_runs: [run, %RoleRun{id: "rr_unknown", role_id: "unknown_custom_role", status: :pending}],
        selected_run: %RoleRun{id: "rr_unknown", role_id: 12_345, status: :pending},
        selected_role_id: "unknown_custom_role",
        selected_role: nil,
        roles_map: %{},
        transcript: transcript,
        expanded_activities: nil,
        show_raw_log: false
      )

    assert html_fallbacks =~ "Unknown Custom Role"
    assert html_fallbacks =~ "Tool activity (1 step)"
  end

  test "renders raw log colors for stderr and denied lines" do
    run = %RoleRun{id: "rr_stderr", role_id: "engineer", status: :failed}

    lines = [
      "[stderr] execution crashed",
      "[denied] command blocked by policy",
      "[handoff → architect] Handoff message"
    ]

    html =
      render_component(&ConversationTab.raw_log_view/1,
        run: run,
        log_lines: lines,
        runs: nil,
        roles_map: %{}
      )

    assert html =~ "text-red-400"
    assert html =~ "[stderr] execution crashed"
    assert html =~ "[denied] command blocked by policy"
    assert html =~ "Handoff message"
  end

  test "renders properly via CoreComponents.conversation_tab delegation" do
    task = %Task{id: "tsk_core", stage: :product}

    html =
      render_component(&CoreComponents.conversation_tab/1,
        task: task,
        ordered_runs: [],
        selected_run: nil,
        selected_role_id: nil,
        selected_role: nil
      )

    assert html =~ "No role has run this task yet."
  end
end
