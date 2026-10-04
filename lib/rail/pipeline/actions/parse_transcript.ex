defmodule Rail.Pipeline.Actions.ParseTranscript do
  @moduledoc false

  import Rail.Pipeline.Utils.DrivingLine

  alias Rail.Pipeline.Turn

  @human_prefix ~r/^\[human(?::([^\]\s]+))?\]\s*/
  @reminder_prefix ~r/^\[(reminder \d+ of \d+|answered from past answers)\]\s*/
  @system_prefix ~r/^\[(run|init|tool|tool error|result|rail|handoff|denied|recovered|error|rate limit|stderr|human)(\s|\]|:)/

  @doc """
  Reads a run's log lines back as a list of conversational turns.

  Consecutive lines of the same kind group into one turn: everything a human
  typed until the harness says otherwise, everything the role said until a tool
  call interrupts, each run of tool lines as one activity block, and each note
  Rail sent the agent on its own as one reminder. A browser step is the
  exception: each one is its own turn, because each one is a separate thing that
  happened to the page.

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

    initial_state = %{human_lines: nil, sender_id: nil, reminder: nil, activity_lines: [], role_lines: [], turns: []}

    flat_lines
    |> Enum.reduce(initial_state, &process_log_line/2)
    |> flush_reminder()
    |> flush_human()
    |> flush_activity()
    |> flush_role()
    |> Map.fetch!(:turns)
    |> Enum.reverse()
  end

  defp process_log_line(line, state) do
    cond do
      Regex.match?(@reminder_prefix, line) ->
        [prefix, label] = Regex.run(@reminder_prefix, line)

        state
        |> flush_human()
        |> flush_activity()
        |> flush_role()
        |> append_reminder_line(label, String.replace_prefix(line, prefix, ""))

      state.reminder != nil ->
        process_log_line(line, flush_reminder(state))

      Regex.match?(@human_prefix, line) ->
        sender_id = @human_prefix |> Regex.run(line) |> Enum.at(1)
        state = state |> flush_activity() |> flush_role()
        # Two people's messages one after the other are two turns, each theirs.
        state = if sender_id == state.sender_id, do: state, else: flush_human(state)

        stripped = Regex.replace(@human_prefix, line, "")
        %{state | human_lines: [stripped | state.human_lines || []], sender_id: sender_id}

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
      driving_line?(line) ->
        state
        |> flush_human()
        |> flush_activity()
        |> flush_role()
        |> append_turn(%Turn{author: :driving, content: line})

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

  # What Rail did to the page: an instruction, then each step it actually took.
  # One turn each rather than a block of them, because they are separate things
  # that happened and a reader is counting them.
  defp driving_line?(line), do: driving_line(line) != nil

  defp tool_line?(line) do
    String.starts_with?(line, "[tool ") or String.starts_with?(line, "[tool]") or
      String.starts_with?(line, "[tool error")
  end

  defp append_activity_line(state, line), do: %{state | activity_lines: [line | state.activity_lines]}
  defp append_role_line(state, line), do: %{state | role_lines: [line | state.role_lines]}
  defp append_turn(state, turn), do: %{state | turns: [turn | state.turns]}

  defp append_reminder_line(%{reminder: {label, lines}} = state, label, line) do
    %{state | reminder: {label, [line | lines]}}
  end

  defp append_reminder_line(state, label, line), do: %{flush_reminder(state) | reminder: {label, [line]}}

  defp flush_reminder(%{reminder: nil} = state), do: state

  defp flush_reminder(%{reminder: {label, lines}} = state) do
    turn = %Turn{author: :reminder, label: label, content: joined(lines)}
    %{state | reminder: nil, turns: [turn | state.turns]}
  end

  defp flush_human(%{human_lines: nil} = state), do: state

  defp flush_human(%{human_lines: lines} = state) do
    turn = %Turn{author: :human, content: joined(lines), sender_id: state.sender_id}
    %{state | human_lines: nil, sender_id: nil, turns: [turn | state.turns]}
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
