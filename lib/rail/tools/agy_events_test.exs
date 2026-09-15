defmodule Rail.Tools.AgyEventsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.AgyEvents

  test "parses init event, updates conversation id and logs tool count" do
    state = AgyEvents.new()

    event = %{
      "event" => "init",
      "conversation_id" => "conv-xyz",
      "init" => %{"tools" => ["view_file", "run_command"]}
    }

    state = AgyEvents.handle_event(state, event)

    assert state.conversation_id == "conv-xyz"
    assert state.logs == ["[init] conversation conv-xyz · 2 tools"]
  end

  test "sums per-step usage and accumulates tokens" do
    state = AgyEvents.new()

    step1 = %{
      "event" => "step_update",
      "step_update" => %{
        "conversation_id" => "conv-xyz",
        "step_type" => "agent_response",
        "state" => "DONE",
        "text_delta" => "First pass.",
        "usage" => %{
          "input_tokens" => 100,
          "output_tokens" => 10,
          "thinking_tokens" => 4,
          "cache_read_tokens" => 900
        }
      }
    }

    step2 = %{
      "event" => "step_update",
      "step_update" => %{
        "conversation_id" => "conv-xyz",
        "step_type" => "agent_response",
        "state" => "DONE",
        "text_delta" => "Second pass.",
        "usage" => %{
          "input_tokens" => 200,
          "output_tokens" => 30,
          "thinking_tokens" => 6,
          "cache_read_tokens" => 1800
        }
      }
    }

    result = %{
      "event" => "result",
      "result" => %{
        "conversation_id" => "conv-xyz",
        "status" => "SUCCESS",
        "response" => "Final answer.",
        "num_turns" => 2,
        "usage" => %{"input_tokens" => 200, "output_tokens" => 30}
      }
    }

    state =
      state
      |> AgyEvents.handle_event(step1)
      |> AgyEvents.handle_event(step2)
      |> AgyEvents.handle_event(result)

    assert state.conversation_id == "conv-xyz"
    assert state.final_text == "Final answer."
    assert state.num_turns == 2
    assert state.thinking_tokens == 10

    assert %Run.Usage{} = state.usage
    assert state.usage.input_tokens == 300
    assert state.usage.output_tokens == 40
    assert state.usage.cache_read_input_tokens == 2700

    assert AgyEvents.success?(state)
    refute AgyEvents.reported_failure?(state)
  end

  test "falls back to result usage when no step reported any" do
    state = AgyEvents.new()

    result_event = %{
      "event" => "result",
      "result" => %{
        "status" => "SUCCESS",
        "response" => "done",
        "num_turns" => 1,
        "usage" => %{
          "input_tokens" => 50,
          "output_tokens" => 5,
          "cache_read_tokens" => 100
        }
      }
    }

    state = AgyEvents.handle_event(state, result_event)

    assert state.usage.input_tokens == 50
    assert state.usage.output_tokens == 5
    assert state.usage.cache_read_input_tokens == 100
    assert state.num_turns == 1
  end

  test "logs tool calls on ACTIVE and tool errors on ERROR, but ignores DONE" do
    state = AgyEvents.new()

    active_step = %{
      "event" => "step_update",
      "step_update" => %{
        "state" => "ACTIVE",
        "step_type" => "tool",
        "tool_name" => "view_file",
        "tool_info" => %{
          "parameters" => %{"AbsolutePath" => "/repo/lib/main.dart"}
        }
      }
    }

    done_step = %{
      "event" => "step_update",
      "step_update" => %{
        "state" => "DONE",
        "step_type" => "tool",
        "tool_name" => "view_file",
        "tool_info" => %{
          "parameters" => %{"AbsolutePath" => "/repo/lib/main.dart"}
        }
      }
    }

    error_step = %{
      "event" => "step_update",
      "step_update" => %{
        "state" => "ERROR",
        "step_type" => "tool",
        "tool_name" => "run_command",
        "text_delta" => "permission denied",
        "tool_info" => %{
          "parameters" => %{"CommandLine" => "ls"}
        }
      }
    }

    state =
      state
      |> AgyEvents.handle_event(active_step)
      |> AgyEvents.handle_event(done_step)
      |> AgyEvents.handle_event(error_step)

    assert state.logs == [
             "[tool] view_file /repo/lib/main.dart",
             "[tool error] run_command permission denied"
           ]
  end

  test "tool ERROR step without text_delta falls back to tool parameters summary" do
    state = AgyEvents.new()

    error_step = %{
      "event" => "step_update",
      "step_update" => %{
        "state" => "ERROR",
        "step_type" => "tool",
        "tool_name" => "fetch_url",
        "tool_info" => %{
          "parameters" => %{"url" => "https://invalid.local"}
        }
      }
    }

    state = AgyEvents.handle_event(state, error_step)
    assert state.logs == ["[tool error] fetch_url https://invalid.local"]
  end

  test "surfaces refused actions on an otherwise successful run" do
    state = AgyEvents.new()

    result_event = %{
      "event" => "result",
      "result" => %{
        "status" => "SUCCESS",
        "response" => "",
        "denied_actions" => [
          %{"action" => "command", "display_name" => "RunCommand"}
        ]
      }
    }

    state = AgyEvents.handle_event(state, result_event)

    assert Enum.any?(state.logs, &(&1 =~ "[denied] agy refused: RunCommand"))
    assert AgyEvents.success?(state)
    refute AgyEvents.reported_failure?(state)
  end

  test "status ERROR fails the run when answer was not finished" do
    state = AgyEvents.new()

    mid_step = %{
      "event" => "step_update",
      "step_update" => %{
        "conversation_id" => "conv-10",
        "step_type" => "agent_response",
        "state" => "ACTIVE",
        "text_delta" => "Rebasing onto main"
      }
    }

    error_result = %{
      "event" => "result",
      "result" => %{
        "conversation_id" => "conv-10",
        "status" => "ERROR",
        "response" => "Rebasing onto main",
        "error" => "stream disconnected"
      }
    }

    state =
      state
      |> AgyEvents.handle_event(mid_step)
      |> AgyEvents.handle_event(error_result)

    assert AgyEvents.reported_failure?(state)
    refute AgyEvents.success?(state)
    refute AgyEvents.recovered?(state)
    assert state.result_error == "agy reported ERROR: stream disconnected"

    # The conversation says why, and a result that spent nothing says only its status.
    assert Enum.take(state.logs, -2) == ["[error] agy reported ERROR: stream disconnected", "[result] ERROR"]
  end

  test "status ERROR after a finished answer is recovered and does not fail run" do
    state = AgyEvents.new()

    done_step = %{
      "event" => "step_update",
      "step_update" => %{
        "conversation_id" => "conv-9",
        "step_type" => "agent_response",
        "state" => "DONE",
        "text_delta" => "Rebased, tests pass, PR #13 updated."
      }
    }

    error_result = %{
      "event" => "result",
      "result" => %{
        "conversation_id" => "conv-9",
        "status" => "ERROR",
        "response" => "Rebased, tests pass, PR #13 updated.",
        "error" => "Your previous response contained an improperly formatted function call."
      }
    }

    state =
      state
      |> AgyEvents.handle_event(done_step)
      |> AgyEvents.handle_event(error_result)

    assert AgyEvents.recovered?(state)
    assert AgyEvents.success?(state)
    refute AgyEvents.reported_failure?(state)
    assert state.recovered_status == "ERROR"
    assert is_nil(state.result_error)

    assert Enum.any?(state.logs, &(&1 =~ "[recovered] agy reported ERROR"))
    assert Enum.any?(state.logs, &(&1 =~ "[result] ERROR (recovered)"))
  end

  test "parse_line decodes NDJSON or logs non-JSON stdout" do
    state = AgyEvents.new()

    state = AgyEvents.parse_line(state, "Non-JSON CLI message")
    assert state.logs == ["Non-JSON CLI message"]

    state = AgyEvents.parse_line(state, "  \n  ")
    assert state.logs == ["Non-JSON CLI message"]

    json_line = Jason.encode!(%{"event" => "init", "conversation_id" => "conv-1", "init" => %{"tools" => []}})
    state = AgyEvents.parse_line(state, json_line)
    assert state.conversation_id == "conv-1"

    state = AgyEvents.parse_line(state, "{bad json")
    assert length(state.logs) == 3
  end

  test "ignores unhandled event types and non-map structures" do
    state = AgyEvents.new()
    state = AgyEvents.handle_event(state, %{"event" => "unknown"})
    assert state.logs == []

    state = AgyEvents.handle_event(state, %{"event" => "step_update", "step_update" => nil})
    assert state.logs == []

    state =
      AgyEvents.handle_event(state, %{
        "event" => "step_update",
        "step_update" => %{"step_type" => "unknown_step", "state" => "DONE"}
      })

    assert state.logs == []

    empty_text_step = %{
      "event" => "step_update",
      "step_update" => %{
        "step_type" => "agent_response",
        "state" => "DONE",
        "text_delta" => "   \n"
      }
    }

    state = AgyEvents.handle_event(state, empty_text_step)
    assert state.response_complete
    assert state.assistant_text == ""

    tool_no_params = %{
      "event" => "step_update",
      "step_update" => %{
        "step_type" => "tool",
        "tool_name" => "noop",
        "state" => "ACTIVE",
        "tool_info" => %{"parameters" => %{}}
      }
    }

    state = AgyEvents.handle_event(state, tool_no_params)
    assert state.logs == ["[tool] noop"]

    state = AgyEvents.handle_event(state, %{"event" => "init", "conversation_id" => "   "})
    assert is_nil(state.conversation_id)

    state = AgyEvents.handle_event(state, %{"event" => "result", "result" => nil})
    assert state.saw_result
  end

  test "handles result with empty error string and non-integer usage tokens" do
    state = AgyEvents.new()

    event = %{
      "event" => "result",
      "result" => %{
        "status" => "ERROR",
        "error" => "   ",
        "response" => "",
        "usage" => %{
          "input_tokens" => 12.0,
          "output_tokens" => "50",
          "cache_read_tokens" => "bad_token"
        }
      }
    }

    state = AgyEvents.handle_event(state, event)
    assert state.result_error == "agy reported ERROR"
    assert state.usage.input_tokens == 12
    assert state.usage.output_tokens == 50
    assert state.usage.cache_read_input_tokens == 0
  end
end
