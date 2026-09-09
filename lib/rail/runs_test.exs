defmodule Rail.RunsTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ClaudeEvents
  alias Rail.Runs.QuestionDetector

  test "delegates build_argv/1" do
    argv =
      Runs.build_argv(
        backend: :claude,
        prompt: "Check types",
        model: "claude-3-7-sonnet"
      )

    assert argv == [
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
    assert %QuestionDetector{} = Runs.detect_question("[QUESTION: Which db?]")
    assert %QuestionDetector{task_id: "tsk_1"} = Runs.detect_question("[QUESTION: Which db?]", task_id: "tsk_1")
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
end
