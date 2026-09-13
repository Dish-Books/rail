defmodule Rail.Runs.ClaudeEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Runs.Schemas.Run
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

    assert [%DetectedQuestion{prompt: "Scope to one repo?", options: ["yes", "no"]}] =
             state.detected_questions
  end

  test "assistant text ignores placeholder questions and keeps every real question" do
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
    assert state.detected_questions == []

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

    assert Enum.map(state.detected_questions, & &1.prompt) == [
             "First real question?",
             "Second ignored question?"
           ]
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
    assert state.detected_questions == []
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

    assert %Run.Usage{} = state.usage
    assert state.usage.input_tokens == 10
    assert state.usage.output_tokens == 20
    assert state.usage.cache_read_input_tokens == 1000
    assert state.usage.cache_creation_input_tokens == 500

    assert ClaudeEvents.success?(state)
    refute ClaudeEvents.reported_failure?(state)
    assert Enum.any?(state.logs, &(&1 =~ "[result] success"))
  end

  test "result event with string and float token counts parses correctly" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "result",
      "subtype" => "success",
      "num_turns" => 2,
      "usage" => %{
        "input_tokens" => "100",
        "output_tokens" => 50.0
      }
    }

    state = ClaudeEvents.handle_event(state, event)
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

  test "handles result event with empty final_text on error and an unreadable token count" do
    state = ClaudeEvents.new()

    event = %{
      "type" => "result",
      "subtype" => "error_empty",
      "result" => "",
      "is_error" => true,
      "usage" => %{
        "input_tokens" => "bad_int",
        "output_tokens_details" => %{"thinking_tokens" => "15"}
      }
    }

    state = ClaudeEvents.handle_event(state, event)

    assert state.result_error == "claude reported error_empty"
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
