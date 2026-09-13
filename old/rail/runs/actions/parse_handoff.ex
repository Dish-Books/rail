defmodule Rail.Runs.Actions.ParseHandoff do
  @moduledoc false
  alias Rail.Runs.Handoff

  @received_marker "←"

  # Standard Rail arrow syntax: [handoff ← architect] summary
  @arrow_pattern ~r/^\[handoff ([←→]) ([A-Za-z0-9_-]+)\]\s*(.*)$/u
  # Colon syntax: [handoff: architect] summary
  @colon_pattern ~r/^\[handoff:\s*([A-Za-z0-9_-]+)\]\s*(.*)$/u
  # Explicit direction: [handoff received: architect] or [handoff sent: reviewer]
  @named_direction_pattern ~r/^\[handoff\s+(received|sent):\s*([A-Za-z0-9_-]+)\]\s*(.*)$/ui

  @doc """
  Reads a log line as a handoff, or returns nil for any other line.

  Three syntaxes have been written into logs over time and all three still turn
  up in runs already on disk, so all three are read.
  """
  def parse_handoff(nil), do: nil

  def parse_handoff(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      match = Regex.run(@arrow_pattern, trimmed) ->
        [_line, marker, role_id, summary] = match
        direction = if marker == @received_marker, do: :received, else: :sent
        handoff(role_id, direction, summary)

      match = Regex.run(@colon_pattern, trimmed) ->
        [_line, role_id, summary] = match
        handoff(role_id, :received, summary)

      match = Regex.run(@named_direction_pattern, trimmed) ->
        [_line, direction, role_id, summary] = match
        direction = if String.downcase(direction) == "sent", do: :sent, else: :received
        handoff(role_id, direction, summary)

      true ->
        nil
    end
  end

  defp handoff(role_id, direction, summary) do
    %Handoff{role_id: role_id, direction: direction, summary: String.trim(summary)}
  end
end
