defmodule Rail.Tools.AgyEvents do
  @moduledoc """
  Parses NDJSON event streams emitted by the Agy CLI (`agy --output-format stream-json`).

  Handles conversation initialization, step updates (agent responses, tool start/error states,
  per-step token accumulation), denied action warnings, recovered error handling,
  and final execution results.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.ToolSummarizer

  defstruct [
    :conversation_id,
    :result_error,
    :recovered_status,
    logs: [],
    final_text: "",
    assistant_text: "",
    usage: %Run.Usage{},
    num_turns: 0,
    thinking_tokens: 0,
    saw_result: false,
    response_complete: false
  ]

  @doc """
  Initializes a new Agy event parser state struct.
  """
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    new(Map.new(opts))
  end

  def new(opts) when is_map(opts) do
    %__MODULE__{
      conversation_id: opts[:conversation_id],
      usage: opts[:usage] || %Run.Usage{},
      num_turns: opts[:num_turns] || 0,
      thinking_tokens: opts[:thinking_tokens] || 0
    }
  end

  @doc """
  Parses a raw NDJSON line from the Agy stdout stream.

  Non-JSON stdout is captured as a raw log line. Empty lines are ignored.
  """
  def parse_line(%__MODULE__{} = state, line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        state

      String.starts_with?(trimmed, "{") ->
        case Jason.decode(line) do
          {:ok, %{} = event} ->
            handle_event(state, event)

          {:error, _decode_error} ->
            append_log(state, line)
        end

      true ->
        append_log(state, line)
    end
  end

  @doc """
  Dispatches a decoded JSON event map to the appropriate handler based on its `"event"` name.
  """
  def handle_event(%__MODULE__{} = state, %{"event" => "init"} = event) do
    state = maybe_update_conversation_id(state, event["conversation_id"])
    tools_count = count_list(get_in(event, ["init", "tools"]))
    id_display = state.conversation_id || "?"
    log_line = "[init] conversation #{id_display} · #{tools_count} tools"

    append_log(state, log_line)
  end

  def handle_event(%__MODULE__{} = state, %{"event" => "step_update"} = event) do
    case event["step_update"] do
      %{} = step ->
        state = maybe_update_conversation_id(state, step["conversation_id"])
        step_type = step["step_type"]
        step_state = step["state"]
        text_delta = step["text_delta"] || ""

        state =
          cond do
            step_type == "agent_response" ->
              handle_agent_response(state, text_delta, step_state)

            step_type == "tool" ->
              handle_tool_step(state, step, text_delta, step_state)

            true ->
              state
          end

        accumulate_step_usage(state, step["usage"])

      _missing_step ->
        state
    end
  end

  def handle_event(%__MODULE__{} = state, %{"event" => "result"} = event) do
    case event["result"] do
      %{} = result ->
        handle_result(state, result)

      _missing_result ->
        %{state | saw_result: true}
    end
  end

  # Private Handlers

  def handle_event(%__MODULE__{} = state, _unhandled_event) do
    state
  end

  @doc "Returns true if the run failed due to an unrecovered error."
  def reported_failure?(%__MODULE__{result_error: err}), do: is_binary(err)

  @doc "Returns true if the run completed cleanly without unrecovered failure."
  def success?(%__MODULE__{saw_result: true, result_error: nil}), do: true
  def success?(%__MODULE__{}), do: false

  @doc "Returns true if the run had a non-SUCCESS status but recovered because an answer reached DONE."
  def recovered?(%__MODULE__{recovered_status: status}), do: is_binary(status)

  defp handle_agent_response(state, text_delta, step_state) do
    trimmed_text = String.trim_trailing(text_delta)
    response_complete = step_state == "DONE"

    state = %{state | response_complete: response_complete}

    if trimmed_text == "" do
      state
    else
      new_assistant_text = state.assistant_text <> trimmed_text <> "\n"
      lines = String.split(trimmed_text, "\n")

      %{
        state
        | assistant_text: new_assistant_text,
          logs: Enum.concat(state.logs, lines)
      }
    end
  end

  defp handle_tool_step(state, step, _text_delta, "ACTIVE") do
    name = step["tool_name"] || "tool"
    params = get_in(step, ["tool_info", "parameters"]) || %{}
    summary = ToolSummarizer.summarize_tool_input(name, params)

    log_line =
      if summary == "" do
        "[tool] #{name}"
      else
        "[tool] #{name} #{summary}"
      end

    append_log(state, log_line)
  end

  defp handle_tool_step(state, step, text_delta, "ERROR") do
    name = step["tool_name"] || "tool"
    params = get_in(step, ["tool_info", "parameters"]) || %{}

    detail =
      if text_delta == "" do
        ToolSummarizer.summarize_tool_input(name, params)
      else
        text_delta
      end

    log_line = "[tool error] #{name} #{ToolSummarizer.truncate(detail, 300)}"
    append_log(state, log_line)
  end

  defp handle_tool_step(state, _step, _text_delta, _other_state), do: state

  defp accumulate_step_usage(state, %{} = step_usage) do
    parsed_usage = parse_agy_usage(step_usage)
    new_usage = Run.add_usage(state.usage, parsed_usage)
    thinking = state.thinking_tokens + to_int(step_usage["thinking_tokens"])

    %{state | usage: new_usage, thinking_tokens: thinking}
  end

  defp accumulate_step_usage(state, _missing_usage), do: state

  defp handle_result(state, result) do
    state = maybe_update_conversation_id(state, result["conversation_id"])
    final_text = result["response"] || ""

    logs_with_denied = maybe_log_denied_actions(state.logs, result["denied_actions"])

    usage =
      if is_nil(Run.usage(state.usage)) and is_map(result["usage"]) do
        parse_agy_usage(result["usage"])
      else
        state.usage
      end

    num_turns = to_int(result["num_turns"])
    status = result["status"] || "SUCCESS"

    {result_error, recovered_status, final_logs} =
      process_status(
        logs_with_denied,
        status,
        result["error"],
        state.response_complete,
        final_text
      )

    status_label =
      if recovered_status do
        "#{status} (recovered)"
      else
        "#{status}"
      end

    result_log = Enum.join(["[result] #{status_label}" | List.wrap(Run.usage(usage))], " · ")

    # The error is what the human has to read to know what to do next, so it is
    # said in the conversation and not only on the run.
    error_logs = if result_error, do: ["[error] #{result_error}"], else: []

    %{
      state
      | saw_result: true,
        final_text: final_text,
        usage: usage,
        num_turns: num_turns,
        result_error: result_error,
        recovered_status: recovered_status,
        logs: Enum.concat([final_logs, error_logs, [result_log]])
    }
  end

  defp maybe_log_denied_actions(logs, denied) when is_list(denied) and denied != [] do
    names =
      denied
      |> Enum.filter(&is_map/1)
      |> Enum.map_join(", ", fn d -> d["display_name"] || d["action"] || "action" end)

    Enum.concat(logs, ["[denied] agy refused: #{names}"])
  end

  defp maybe_log_denied_actions(logs, _no_denied), do: logs

  defp process_status(logs, "SUCCESS", _error, _response_complete, _final_text) do
    {nil, nil, logs}
  end

  defp process_status(logs, status, error, response_complete, final_text) do
    detail = error |> to_string() |> String.trim()

    described =
      "agy reported #{status}" <>
        if detail == "" do
          ""
        else
          ": #{ToolSummarizer.truncate(detail, 300)}"
        end

    if response_complete and String.trim(final_text) != "" do
      recovered_log = "[recovered] #{described}"
      {nil, to_string(status), Enum.concat(logs, [recovered_log])}
    else
      {described, nil, logs}
    end
  end

  defp maybe_update_conversation_id(state, conversation_id) when is_binary(conversation_id) and conversation_id != "" do
    if String.trim(conversation_id) == "" do
      state
    else
      %{state | conversation_id: conversation_id}
    end
  end

  defp maybe_update_conversation_id(state, _invalid_conv_id), do: state

  defp append_log(state, line) do
    %{state | logs: Enum.concat(state.logs, [line])}
  end

  defp count_list(list) when is_list(list), do: length(list)
  defp count_list(_non_list), do: 0

  defp parse_agy_usage(usage_map) when is_map(usage_map) do
    %Run.Usage{
      input_tokens: to_int(usage_map["input_tokens"]),
      output_tokens: to_int(usage_map["output_tokens"]),
      cache_read_input_tokens: to_int(usage_map["cache_read_tokens"]),
      cache_creation_input_tokens: 0
    }
  end

  defp to_int(v) when is_integer(v), do: v
  defp to_int(v) when is_float(v), do: round(v)

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {num, _rest} -> num
      :error -> 0
    end
  end

  defp to_int(_other_val), do: 0
end
