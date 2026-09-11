defmodule Rail.Runs.ClaudeEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.TaskUsage
  alias Rail.Runs.ClaudeEvents
  alias Rail.Runs.DetectedQuestion

  test "parses system init event, captures session id and logs tool/server counts" do
    state = ClaudeEvents.new(task_id: "task-1", role_id: "role-1")

    event = %{
      "type" => "system",
      "subtype" => "init",
      "session_id" => "sess-abc-123",
      "tools" => ["read_file", "write_file"],
      "mcp_servers" => ["linear"]
    }

    state = ClaudeEvents.handle_event(state, event)

    assert state.conversation_id == "sess-abc-123"
    assert state.logs == ["[init] session sess-abc-123 · 2 tools · 1 MCP servers"]
  end

  test "system event without init subtype updates session id without logging" do
    state = ClaudeEvents.new()
    event = %{"type" => "system", "session_id" => "sess-999"}
    state = ClaudeEvents.handle_event(state, event)

    assert state.conversation_id == "sess-999"
    assert state.logs == []
  end

  test "system init event handles missing tools or mcp_servers" do
    state = ClaudeEvents.new()
    event = %{"type" => "system", "subtype" => "init"}
    state = ClaudeEvents.handle_event(state, event)

    assert state.logs == ["[init] session ? · 0 tools · 0 MCP servers"]
  end

  test "parses assistant prose and extracts questions" do
    state = ClaudeEvents.new(task_id: "tsk_1", role_id: "rol_eng")

    event = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{
            "type" => "text",
            "text" => "Analyzing repository...\n[QUESTION: Scope to one repo?] [OPTIONS: yes, no]\n"
          }
        ]
      }
    }

    state = ClaudeEvents.handle_event(state, event)

    assert state.assistant_text ==
             "Analyzing repository...\n[QUESTION: Scope to one repo?] [OPTIONS: yes, no]\n"

    assert state.logs == [
             "Analyzing repository...",
             "[QUESTION: Scope to one repo?] [OPTIONS: yes, no]"
           ]

    assert %DetectedQuestion{} = state.detected_question
    assert state.detected_question.prompt == "Scope to one repo?"
    assert state.detected_question.options == ["yes", "no"]
  end

  test "assistant text ignores placeholder questions and keeps only the first question" do
    state = ClaudeEvents.new(task_id: "tsk_1", role_id: "rol_eng")

    first_event = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "text", "text" => "[QUESTION: <question>]"}
        ]
      }
    }

    state = ClaudeEvents.handle_event(state, first_event)
    assert is_nil(state.detected_question)

    second_event = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "text", "text" => "[QUESTION: First real question?]"},
          %{"type" => "text", "text" => "[QUESTION: Second ignored question?]"}
        ]
      }
    }

    state = ClaudeEvents.handle_event(state, second_event)
    assert state.detected_question.prompt == "First real question?"
  end

  test "parses assistant tool_use event and logs tool summary" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_use",
            "name" => "Read",
            "input" => %{"file_path" => "/repo/main.dart"}
          },
          %{
            "type" => "tool_use",
            "name" => "empty_tool",
            "input" => %{}
          }
        ]
      }
    }

    state = ClaudeEvents.handle_event(state, event)
    assert state.logs == ["[tool] Read /repo/main.dart", "[tool] empty_tool"]
  end

  test "user event logs tool errors and ignores successful tool results" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "is_error" => false,
            "content" => "File contents [QUESTION: ignored question marker in tool output]"
          },
          %{
            "type" => "tool_result",
            "is_error" => true,
            "content" => "File not found: /repo/missing.dart"
          }
        ]
      }
    }

    state = ClaudeEvents.handle_event(state, event)

    assert state.logs == ["[tool error] File not found: /repo/missing.dart"]
    assert is_nil(state.detected_question)
  end

  test "rate_limit_event logs when status is not allowed" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{
        "status" => "throttled",
        "resetsAt" => "2026-09-09T18:00:00Z"
      }
    }

    state = ClaudeEvents.handle_event(state, event)
    assert state.logs == ["[rate limit] throttled until 2026-09-09T18:00:00Z"]

    allowed_event = %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{"status" => "allowed"}
    }

    state2 = ClaudeEvents.handle_event(state, allowed_event)
    assert state2.logs == state.logs
  end

  test "result event maps cumulative usage, cost, turns, and logs result" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "result",
      "subtype" => "success",
      "session_id" => "sess-final-1",
      "result" => "All done.",
      "num_turns" => 3,
      "total_cost_usd" => 0.125,
      "usage" => %{
        "input_tokens" => 10,
        "output_tokens" => 20,
        "cache_read_input_tokens" => 1000,
        "cache_creation_input_tokens" => 500,
        "output_tokens_details" => %{"thinking_tokens" => 7}
      }
    }

    state = ClaudeEvents.handle_event(state, event)

    assert state.saw_result
    assert state.conversation_id == "sess-final-1"
    assert state.final_text == "All done."
    assert state.num_turns == 3
    assert state.thinking_tokens == 7

    assert %TaskUsage{} = state.usage
    assert state.usage.input_tokens == 10
    assert state.usage.output_tokens == 20
    assert state.usage.cache_read_input_tokens == 1000
    assert state.usage.cache_creation_input_tokens == 500
    assert Decimal.equal?(state.usage.total_cost, Decimal.new("0.125"))

    assert ClaudeEvents.success?(state)
    refute ClaudeEvents.reported_failure?(state)
    assert Enum.any?(state.logs, &(&1 =~ "[result] success"))
  end

  test "result event with string cost and float turns parses correctly" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "result",
      "subtype" => "success",
      "total_cost_usd" => "0.0450",
      "num_turns" => 2,
      "usage" => %{
        "input_tokens" => "100",
        "output_tokens" => 50.0
      }
    }

    state = ClaudeEvents.handle_event(state, event)
    assert Decimal.equal?(state.usage.total_cost, Decimal.new("0.0450"))
    assert state.usage.input_tokens == 100
    assert state.usage.output_tokens == 50
  end

  test "result event with error subtype or is_error fails the run" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "result",
      "subtype" => "error_max_turns",
      "result" => "Ran out of turns",
      "is_error" => true,
      "usage" => %{"input_tokens" => 100}
    }

    state = ClaudeEvents.handle_event(state, event)

    assert ClaudeEvents.reported_failure?(state)
    refute ClaudeEvents.success?(state)
    assert state.result_error == "claude reported error_max_turns: Ran out of turns"
  end

  test "parse_line decodes NDJSON or logs non-JSON stdout" do
    state = ClaudeEvents.new()

    state = ClaudeEvents.parse_line(state, "Warning: running on macOS")
    assert state.logs == ["Warning: running on macOS"]

    state = ClaudeEvents.parse_line(state, "   ")
    assert state.logs == ["Warning: running on macOS"]

    json_line = Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "s1"})
    state = ClaudeEvents.parse_line(state, json_line)
    assert state.conversation_id == "s1"
    assert length(state.logs) == 2

    state = ClaudeEvents.parse_line(state, "{not valid json")
    assert length(state.logs) == 3
  end

  test "ignores unhandled event types and non-list content" do
    state = ClaudeEvents.new()
    state = ClaudeEvents.handle_event(state, %{"type" => "thinking", "data" => "..."})
    assert state.logs == []

    state = ClaudeEvents.handle_event(state, %{"type" => "assistant", "message" => %{"content" => nil}})
    assert state.logs == []

    state =
      ClaudeEvents.handle_event(state, %{"type" => "assistant", "message" => %{"content" => [%{"type" => "unknown"}]}})

    assert state.logs == []

    state =
      ClaudeEvents.handle_event(state, %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "   \n"}]}
      })

    assert state.assistant_text == ""

    state = ClaudeEvents.handle_event(state, %{"type" => "user", "message" => nil})
    assert state.logs == []

    state = ClaudeEvents.handle_event(state, %{"type" => "system", "session_id" => "   "})
    assert is_nil(state.conversation_id)
  end

  test "handles result event with empty final_text on error and invalid cost string" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "result",
      "subtype" => "error_empty",
      "result" => "",
      "is_error" => true,
      "total_cost_usd" => "invalid_cost",
      "usage" => %{
        "input_tokens" => "bad_int",
        "output_tokens_details" => %{"thinking_tokens" => "15"}
      }
    }

    state = ClaudeEvents.handle_event(state, event)

    assert state.result_error == "claude reported error_empty"
    assert is_nil(state.usage.total_cost)
    assert state.usage.input_tokens == 0
    assert state.thinking_tokens == 15
  end

  test "handles result event without usage map" do
    state = ClaudeEvents.new()
    event = %{"type" => "result", "subtype" => "success", "result" => "ok"}
    state = ClaudeEvents.handle_event(state, event)
    assert state.saw_result
  end
end
