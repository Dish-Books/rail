defmodule Rail.Tools.ClaudeEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.ClaudeEvents

  test "parses system init event, captures session id and logs tool/server counts" do
    state = ClaudeEvents.new()

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

  test "parses assistant prose into logs" do
    state = ClaudeEvents.new()

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
  end

  # A refusal comes back answering the call only by its id, so the name the call
  # was made under is what files it, whether the text came as a string or blocks.
  test "a failed result is logged under the name of the tool that failed" do
    call = %{
      "type" => "assistant",
      "message" => %{
        "content" => [
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "mcp__rail__save_finding", "input" => %{"key" => "k"}},
          %{"type" => "tool_use", "id" => "toolu_2", "name" => "Read", "input" => %{"file_path" => "/repo/a.ex"}}
        ]
      }
    }

    refused = %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "toolu_1",
            "is_error" => true,
            "content" => [%{"type" => "text", "text" => "Refused, nothing saved."}, %{"type" => "image"}]
          },
          %{"type" => "tool_result", "tool_use_id" => "toolu_2", "is_error" => true, "content" => %{"odd" => true}}
        ]
      }
    }

    state = ClaudeEvents.new() |> ClaudeEvents.handle_event(call) |> ClaudeEvents.handle_event(refused)

    assert Enum.take(state.logs, -2) == [
             "[tool error mcp__rail__save_finding] Refused, nothing saved.",
             ~s([tool error Read] %{"odd" => true})
           ]
  end

  # A turn stopped part way never writes its result event, so what it spent is
  # counted from each message as it streams, one message arriving in several events.
  test "usage is counted per message as it streams, and the result's own total wins when it comes" do
    said = fn id, input, output ->
      %{
        "type" => "assistant",
        "message" => %{
          "id" => id,
          "content" => [%{"type" => "text", "text" => "Working."}],
          "usage" => %{"input_tokens" => input, "output_tokens" => output, "cache_read_input_tokens" => 10}
        }
      }
    end

    streamed =
      Enum.reduce([said.("msg_1", 100, 5), said.("msg_1", 100, 20), said.("msg_2", 40, 7)], ClaudeEvents.new(), fn event,
                                                                                                                   state ->
        ClaudeEvents.handle_event(state, event)
      end)

    assert %Run.Usage{input_tokens: 140, output_tokens: 27, cache_read_input_tokens: 20} = streamed.usage

    finished =
      ClaudeEvents.handle_event(streamed, %{
        "type" => "result",
        "subtype" => "success",
        "usage" => %{"input_tokens" => 150, "output_tokens" => 30}
      })

    assert %Run.Usage{input_tokens: 150, output_tokens: 30, cache_read_input_tokens: 0} = finished.usage
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
    refute state.authentication_failed

    refused = Map.put(event, "error", "authentication_failed")
    assert %ClaudeEvents{authentication_failed: true} = ClaudeEvents.handle_event(ClaudeEvents.new(), refused)

    assert Enum.take(state.logs, -2) == [
             "[error] claude reported error_max_turns: Ran out of turns",
             "[result] error_max_turns · 100 tokens"
           ]
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

  test "a subagent call is its own line, and everything inside it is tagged with the call" do
    events = [
      %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => "toolu_pm",
              "name" => "Task",
              "input" => %{"subagent_type" => "product", "description" => "write\n the ticket", "prompt" => "Go."}
            }
          ]
        }
      },
      %{
        "type" => "assistant",
        "parent_tool_use_id" => "toolu_pm",
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "Reading the issue.\nSaving it."},
            %{"type" => "tool_use", "id" => "toolu_save", "name" => "mcp__rail__save_ticket", "input" => %{}}
          ]
        }
      },
      %{
        "type" => "user",
        "parent_tool_use_id" => "toolu_pm",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_save",
              "is_error" => true,
              "content" => "Refused, nothing saved. title: is required."
            }
          ]
        }
      },
      %{
        "type" => "user",
        "message" => %{"content" => [%{"type" => "tool_result", "tool_use_id" => "toolu_pm", "content" => "Saved."}]}
      }
    ]

    state = Enum.reduce(events, ClaudeEvents.new(), &ClaudeEvents.handle_event(&2, &1))

    assert state.logs == [
             "[subagent toolu_pm] product · write the ticket",
             "[within toolu_pm] Reading the issue.",
             "[within toolu_pm] Saving it.",
             "[within toolu_pm] [tool] mcp__rail__save_ticket",
             "[within toolu_pm] [tool error mcp__rail__save_ticket] Refused, nothing saved. title: is required.",
             "[subagent end toolu_pm]"
           ]

    # The run's final word is its own, never a subagent's.
    assert state.assistant_text == ""
  end

  test "an Agent call that fails ends with its error, and two at once keep their own tags" do
    call = fn id, type ->
      %{"type" => "tool_use", "id" => id, "name" => "Agent", "input" => %{"subagent_type" => type}}
    end

    said = fn id, text ->
      %{
        "type" => "assistant",
        "parent_tool_use_id" => id,
        "message" => %{"content" => [%{"type" => "text", "text" => text}]}
      }
    end

    events = [
      %{
        "type" => "assistant",
        "message" => %{"content" => [call.("toolu_a", "designer"), call.("toolu_b", "architect")]}
      },
      said.("toolu_a", "Option one."),
      said.("toolu_b", "Reading the code."),
      %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => "toolu_a",
              "is_error" => true,
              "content" => [%{"type" => "text", "text" => "Out of turns"}]
            }
          ]
        }
      }
    ]

    state = Enum.reduce(events, ClaudeEvents.new(), &ClaudeEvents.handle_event(&2, &1))

    assert state.logs == [
             "[subagent toolu_a] designer ·",
             "[subagent toolu_b] architect ·",
             "[within toolu_a] Option one.",
             "[within toolu_b] Reading the code.",
             "[subagent end toolu_a] Out of turns"
           ]
  end

  test "a subagent call with no type, or a blank one, reads as the general one" do
    for input <- ["?", %{"subagent_type" => "  ", "description" => " \n "}] do
      event = %{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "tool_use", "id" => "toolu_g", "name" => "Task", "input" => input}]}
      }

      assert %{logs: ["[subagent toolu_g] general-purpose ·"]} = ClaudeEvents.handle_event(ClaudeEvents.new(), event)
    end
  end
end
