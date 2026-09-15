defmodule Rail.Tools.ClaudeEvents do
  @moduledoc """
  Parses NDJSON event streams emitted by the Claude CLI (`claude --output-format stream-json`).

  Handles system initialization, agent prose and tool use, tool errors, rate limits,
  and final execution results with cumulative usage accounting.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Tools.ToolSummarizer

  defstruct [
    :conversation_id,
    :result_error,
    logs: [],
    final_text: "",
    assistant_text: "",
    usage: %Run.Usage{},
    num_turns: 0,
    thinking_tokens: 0,
    saw_result: false
  ]

  @doc """
  Initializes a new Claude event parser state struct.
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
  Parses a raw NDJSON line from the Claude stdout stream.

  Non-JSON stdout (like banners or warnings) is captured as a raw log line.
  Empty or whitespace-only lines are ignored.
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
  Dispatches a decoded JSON event map to the appropriate handler based on its `"type"`.
  """
  def handle_event(%__MODULE__{} = state, %{"type" => "system"} = event) do
    state = maybe_update_conversation_id(state, event["session_id"])

    if event["subtype"] == "init" do
      tools_count = count_list(event["tools"])
      servers_count = count_list(event["mcp_servers"])
      id_display = state.conversation_id || "?"
      log_line = "[init] session #{id_display} · #{tools_count} tools · #{servers_count} MCP servers"

      append_log(state, log_line)
    else
      state
    end
  end

  def handle_event(%__MODULE__{} = state, %{"type" => "assistant"} = event) do
    content = get_in(event, ["message", "content"])

    if is_list(content) do
      Enum.reduce(content, state, &process_assistant_block/2)
    else
      state
    end
  end

  def handle_event(%__MODULE__{} = state, %{"type" => "user"} = event) do
    content = get_in(event, ["message", "content"])

    if is_list(content) do
      Enum.reduce(content, state, &process_user_block/2)
    else
      state
    end
  end

  def handle_event(%__MODULE__{} = state, %{"type" => "rate_limit_event"} = event) do
    info = event["rate_limit_info"]

    if is_map(info) and info["status"] != "allowed" do
      resets_at = info["resetsAt"] || info["resets_at"]
      log_line = "[rate limit] #{info["status"]} until #{resets_at}"
      append_log(state, log_line)
    else
      state
    end
  end

  def handle_event(%__MODULE__{} = state, %{"type" => "result"} = event) do
    state = maybe_update_conversation_id(state, event["session_id"])
    final_text = event["result"] || ""
    usage = extract_usage(event, state.usage)
    thinking_tokens = extract_thinking_tokens(event, state.thinking_tokens)
    num_turns = to_int(event["num_turns"])
    subtype = event["subtype"]

    is_error =
      event["is_error"] == true or (is_binary(subtype) and subtype != "success")

    result_error =
      if is_error do
        "claude reported #{subtype}" <>
          if final_text == "" do
            ""
          else
            ": #{ToolSummarizer.truncate(final_text, 300)}"
          end
      else
        state.result_error
      end

    result_log = Enum.join(["[result] #{subtype}" | List.wrap(Run.usage(usage))], " · ")

    # The error is what the human has to read to know what to do next, so it is
    # said in the conversation and not only on the run.
    error_logs = if is_error, do: ["[error] #{result_error}"], else: []

    %{
      state
      | saw_result: true,
        final_text: final_text,
        usage: usage,
        thinking_tokens: thinking_tokens,
        num_turns: num_turns,
        result_error: result_error,
        logs: Enum.concat([state.logs, error_logs, [result_log]])
    }
  end

  def handle_event(%__MODULE__{} = state, _unhandled_event) do
    state
  end

  @doc "Returns true if the run failed due to an error reported in result."
  def reported_failure?(%__MODULE__{result_error: err}), do: is_binary(err)

  @doc "Returns true if the run completed cleanly with a success result."
  def success?(%__MODULE__{saw_result: true, result_error: nil}), do: true
  def success?(%__MODULE__{}), do: false

  defp process_assistant_block(%{"type" => "text", "text" => raw_text}, state) when is_binary(raw_text) do
    text = String.trim_trailing(raw_text)

    if text == "" do
      state
    else
      new_assistant_text = state.assistant_text <> text <> "\n"
      lines = String.split(text, "\n")

      %{
        state
        | assistant_text: new_assistant_text,
          logs: Enum.concat(state.logs, lines)
      }
    end
  end

  defp process_assistant_block(%{"type" => "tool_use"} = block, state) do
    name = block["name"] || "tool"
    summary = ToolSummarizer.summarize_tool_input(name, block["input"])

    log_line =
      if summary == "" do
        "[tool] #{name}"
      else
        "[tool] #{name} #{summary}"
      end

    append_log(state, log_line)
  end

  defp process_assistant_block(_other_block, state), do: state

  defp process_user_block(%{"type" => "tool_result", "is_error" => true} = block, state) do
    detail = ToolSummarizer.truncate(to_string(block["content"]), 300)
    append_log(state, "[tool error] #{detail}")
  end

  defp process_user_block(_other_block, state), do: state

  defp maybe_update_conversation_id(state, session_id) when is_binary(session_id) and session_id != "" do
    if String.trim(session_id) == "" do
      state
    else
      %{state | conversation_id: session_id}
    end
  end

  defp maybe_update_conversation_id(state, _invalid_session_id), do: state

  defp append_log(state, line) do
    %{state | logs: Enum.concat(state.logs, [line])}
  end

  defp count_list(list) when is_list(list), do: length(list)
  defp count_list(_non_list), do: 0

  defp extract_usage(event, current_usage) do
    case event["usage"] do
      %{} = u ->
        %Run.Usage{
          input_tokens: to_int(u["input_tokens"]),
          output_tokens: to_int(u["output_tokens"]),
          cache_read_input_tokens: to_int(u["cache_read_input_tokens"]),
          cache_creation_input_tokens: to_int(u["cache_creation_input_tokens"])
        }

      _missing_usage ->
        current_usage
    end
  end

  defp extract_thinking_tokens(event, current_tokens) do
    case get_in(event, ["usage", "output_tokens_details", "thinking_tokens"]) do
      num when is_integer(num) -> num
      str when is_binary(str) -> to_int(str)
      _other_or_nil -> current_tokens
    end
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
