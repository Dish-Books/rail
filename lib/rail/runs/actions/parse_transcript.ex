defmodule Rail.Runs.Actions.ParseTranscript do
  @moduledoc false
  alias Rail.Runs.Turn

  @human_prefix ~r/^\[human\]\s*/
  @system_prefix ~r/^\[(run|init|tool|tool error|result|rail|handoff|denied|recovered|error|rate limit|stderr|human)(\s|\]|:)/

  @doc """
  Reads a run's log lines back as a list of conversational turns.

  Consecutive lines of the same kind group into one turn: everything a human
  typed until the harness says otherwise, everything the role said until a tool
  call interrupts, and each run of tool lines as one activity block.

  Accepts a list of lines or one multiline string; a log with nothing in it
  parses to no turns rather than to an empty turn.
  """
  def parse_transcript(nil), do: []
  def parse_transcript(""), do: []
  def parse_transcript([]), do: []

  def parse_transcript(logs) when is_binary(logs) do
    if String.trim(logs) == "" do
      []
    else
      logs |> String.replace("\r\n", "\n") |> String.split("\n") |> parse_transcript()
    end
  end

  def parse_transcript(logs) when is_list(logs) do
    if Enum.all?(logs, &(String.trim(&1) == "")) do
      []
    else
      do_parse(logs)
    end
  end

  # A log line may itself hold newlines when the harness wrote a block in one
  # event, so the lines are flattened before anything reads them as lines.
  defp do_parse(logs) do
    flat_lines =
      Enum.flat_map(logs, fn entry ->
        if String.contains?(entry, "\n") do
          entry |> String.replace("\r\n", "\n") |> String.split("\n")
        else
          [entry]
        end
      end)

    initial_state = %{human_lines: nil, activity_lines: [], role_lines: [], turns: []}

    flat_lines
    |> Enum.reduce(initial_state, &process_log_line/2)
    |> flush_human()
    |> flush_activity()
    |> flush_role()
    |> Map.fetch!(:turns)
    |> Enum.reverse()
  end

  defp process_log_line(line, state) do
    cond do
      Regex.match?(@human_prefix, line) ->
        state = state |> flush_activity() |> flush_role()

        stripped = Regex.replace(@human_prefix, line, "")
        %{state | human_lines: [stripped | state.human_lines || []]}

      # Only the harness ends what a human was saying: a plain line after a
      # comment is the rest of that comment, however it is indented or wrapped.
      state.human_lines != nil ->
        if Regex.match?(@system_prefix, line) do
          state |> flush_human() |> process_non_human_line(line)
        else
          %{state | human_lines: [line | state.human_lines]}
        end

      true ->
        process_non_human_line(state, line)
    end
  end

  defp process_non_human_line(state, line) do
    cond do
      tool_line?(line) ->
        state
        |> flush_human()
        |> flush_role()
        |> append_activity_line(line)

      Regex.match?(@system_prefix, line) ->
        state
        |> flush_human()
        |> flush_activity()
        |> flush_role()
        |> append_turn(%Turn{author: :event, content: line})

      true ->
        state
        |> flush_human()
        |> flush_activity()
        |> append_role_line(line)
    end
  end

  defp tool_line?(line) do
    String.starts_with?(line, "[tool ") or String.starts_with?(line, "[tool]") or
      String.starts_with?(line, "[tool error")
  end

  defp append_activity_line(state, line), do: %{state | activity_lines: [line | state.activity_lines]}
  defp append_role_line(state, line), do: %{state | role_lines: [line | state.role_lines]}
  defp append_turn(state, turn), do: %{state | turns: [turn | state.turns]}

  defp flush_human(%{human_lines: nil} = state), do: state

  defp flush_human(%{human_lines: lines} = state) do
    turn = %Turn{author: :human, content: joined(lines)}
    %{state | human_lines: nil, turns: [turn | state.turns]}
  end

  defp flush_activity(%{activity_lines: []} = state), do: state

  defp flush_activity(%{activity_lines: lines} = state) do
    turn = %Turn{author: :activity, content: joined(lines)}
    %{state | activity_lines: [], turns: [turn | state.turns]}
  end

  defp flush_role(%{role_lines: []} = state), do: state

  defp flush_role(%{role_lines: lines} = state) do
    turn = %Turn{author: :role, content: joined(lines)}
    %{state | role_lines: [], turns: [turn | state.turns]}
  end

  # Lines are accumulated head-first as each block is read.
  defp joined(lines), do: lines |> Enum.reverse() |> Enum.join("\n")
end
