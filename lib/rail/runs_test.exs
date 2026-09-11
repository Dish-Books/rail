defmodule Rail.RunsTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ClaudeEvents
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.RunEvent

  test "delegates build_args/1" do
    args =
      Runs.build_args(
        backend: :claude,
        prompt: "Check types",
        model: "claude-3-7-sonnet"
      )

    assert args == [
             "-p",
             "Check types",
             "--model",
             "claude-3-7-sonnet",
             "--effort",
             "high",
             "--dangerously-skip-permissions",
             "--output-format",
             "stream-json",
             "--verbose"
           ]
  end

  test "delegates build_prompt/1" do
    prompt = Runs.build_prompt(task_description: "Build landing page")
    assert prompt == "Build landing page\n"
  end

  test "delegates detect_question/1 and detect_question/2" do
    assert %DetectedQuestion{} = Runs.detect_question("[QUESTION: Which db?]")
    assert %DetectedQuestion{task_id: "tsk_1"} = Runs.detect_question("[QUESTION: Which db?]", task_id: "tsk_1")
    assert is_nil(Runs.detect_question("Plain prose"))
  end

  test "delegates summarize_tool_input/1 and summarize_tool_input/2" do
    assert Runs.summarize_tool_input(%{"command" => "mix test"}) == "mix test"
    assert Runs.summarize_tool_input("bash", %{"command" => "mix test"}) == "mix test"
  end

  test "delegates transient?/1" do
    assert Runs.transient?("timed out")
    refute Runs.transient?("unrecognized_model")
  end

  test "new_event_state/2 creates Claude or Agy event state" do
    assert %ClaudeEvents{} = Runs.new_event_state(:claude)
    assert %ClaudeEvents{} = Runs.new_event_state("claude")
    assert %ClaudeEvents{} = Runs.new_event_state("CLAUDE")

    assert %AgyEvents{} = Runs.new_event_state(:agy)
    assert %AgyEvents{} = Runs.new_event_state("agy")
    assert %AgyEvents{} = Runs.new_event_state(:other)
  end

  test "parse_line/2 dispatches to appropriate parser" do
    claude_state = Runs.new_event_state(:claude)
    updated_claude = Runs.parse_line(claude_state, "banner message")
    assert updated_claude.logs == ["banner message"]

    agy_state = Runs.new_event_state(:agy)
    updated_agy = Runs.parse_line(agy_state, "agy message")
    assert updated_agy.logs == ["agy message"]
  end

  test "parse_event/2 dispatches with state struct" do
    claude_state = Runs.new_event_state(:claude)

    updated_claude =
      Runs.parse_event(claude_state, %{"type" => "system", "session_id" => "sess-1"})

    assert updated_claude.conversation_id == "sess-1"

    agy_state = Runs.new_event_state(:agy)

    updated_agy =
      Runs.parse_event(agy_state, %{"event" => "init", "conversation_id" => "conv-1", "init" => %{}})

    assert updated_agy.conversation_id == "conv-1"
  end

  test "parse_event/2 dispatches with backend atom or string" do
    claude_result = Runs.parse_event(:claude, %{"type" => "system", "session_id" => "sess-2"})
    assert %ClaudeEvents{conversation_id: "sess-2"} = claude_result

    agy_result = Runs.parse_event("agy", %{"event" => "init", "conversation_id" => "conv-2", "init" => %{}})
    assert %AgyEvents{conversation_id: "conv-2"} = agy_result
  end

  test "create_role_run/1, get_role_run/1, get_role_run!/1, update_role_run/2" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :starting,
        started_at: DateTime.utc_now()
      })

    assert role_run.id =~ "rr_"
    assert Runs.get_role_run(role_run.id).id == role_run.id
    assert Runs.get_role_run!(role_run.id).id == role_run.id
    assert is_nil(Runs.get_role_run("rr_nonexistent"))

    {:ok, updated} = Runs.update_role_run(role_run, %{status: :running})
    assert updated.status == :running
  end

  test "get_run/1, get_run!/1, list_runs/1, list_active_runs/1" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, run} =
      Runs.start_run(
        role_run,
        :stage,
        ["/bin/sleep", "5"],
        skip_follower: true
      )

    assert Runs.get_run(run.id).id == run.id
    assert Runs.get_run!(run.id).id == run.id
    assert is_nil(Runs.get_run("run_nonexistent"))

    all_runs = Runs.list_runs(task_id: task_id)
    assert length(all_runs) == 1
    assert hd(all_runs).id == run.id

    node_runs = Runs.list_runs(node: run.node, status: :running, ignore_unknown: true)
    assert length(node_runs) == 1

    active_runs = Runs.list_active_runs(role_run_id: role_run.id)
    assert length(active_runs) == 1

    Runs.stop_run(run.id, grace_period: 50)
  end

  test "list_run_events/2 returns events ordered by seq with optional limit" do
    role_id = UXID.generate!(prefix: "rol")
    task_id = UXID.generate!(prefix: "tsk")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    Repo.insert!(%RunEvent{role_run_id: role_run.id, seq: 1, line: "line 1"})
    Repo.insert!(%RunEvent{role_run_id: role_run.id, seq: 2, line: "line 2"})
    Repo.insert!(%RunEvent{role_run_id: role_run.id, seq: 3, line: "line 3"})

    events = Runs.list_run_events(role_run.id)
    assert length(events) == 3
    assert Enum.map(events, & &1.seq) == [1, 2, 3]

    limited = Runs.list_run_events(role_run.id, limit: 2)
    assert length(limited) == 2
  end

  test "on_run_finished/2 broadcasts on PubSub" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "runs")

    run = %Rail.Runs.Schemas.Run{id: "run_test"}
    outcome = %{exit_code: 0}

    assert {:ok, ^outcome} = Runs.on_run_finished(run, outcome)
    assert_receive {:run_finished, ^run, ^outcome}, 500
  end

  test "start_run/4 and stop_run/2 through Runs context" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    {:ok, run} =
      Runs.start_run(role_run, :stage, ["/bin/sleep", "30"], skip_follower: false)

    follower_pid = Runs.get_follower_pid(run.id)
    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)
    assert Runs.is_running?(task_id)
    refute Runs.is_running?("tsk_nonexistent")
    refute Runs.is_running?(123)

    {:ok, stopped} = Runs.stop_run(task_id, grace_period: 50)
    assert stopped.status == :finished
    refute Runs.is_running?(task_id)
  end

  test "adopt_live_runs/1 delegates to Boot" do
    assert Runs.adopt_live_runs(node: "empty_node") == []
  end

  test "append_run_event/2 accepts %RoleRun{} struct and persists sequentially" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, role_run} =
      Runs.create_role_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert %RunEvent{line: "Line from struct", seq: 1} =
             Runs.append_run_event(role_run, "Line from struct")

    assert Runs.chat_prompt("Hi") =~ "Human message:\nHi"
  end

  test "get_latest_role_run_for_task/2 returns latest run" do
    task_id = UXID.generate!(prefix: "tsk")

    assert {:error, :not_found} = Runs.get_latest_role_run_for_task(task_id)
    assert {:error, :not_found} = Runs.get_latest_role_run_for_task(nil)

    role_id_1 = UXID.generate!(prefix: "rol")
    role_id_2 = UXID.generate!(prefix: "rol")
    now = DateTime.utc_now()

    {:ok, %{id: expected_1_id}} =
      Runs.create_role_run(%{task_id: task_id, role_id: role_id_1, status: :finished, started_at: now})

    {:ok, %{id: expected_any_id}} =
      Runs.create_role_run(%{task_id: task_id, role_id: role_id_2, status: :finished, started_at: now})

    assert {:ok, %{id: ^expected_any_id}} = Runs.get_latest_role_run_for_task(task_id)
    assert {:ok, %{id: ^expected_1_id}} = Runs.get_latest_role_run_for_task(task_id, role_id_1)

    other_role_id = UXID.generate!(prefix: "rol")
    assert {:error, :not_found} = Runs.get_latest_role_run_for_task(task_id, other_role_id)
    assert {:error, :not_found} = Runs.get_latest_role_run_for_task(task_id, :reviewer)
  end
end
