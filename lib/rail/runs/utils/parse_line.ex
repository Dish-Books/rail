defmodule Rail.Runs.Utils.ParseLine do
  @moduledoc false

  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ClaudeEvents

  @doc """
  Parses a raw line from an agent NDJSON stdout stream into the accumulator state.
  """
  def parse_line(%ClaudeEvents{} = state, line), do: ClaudeEvents.parse_line(state, line)
  def parse_line(%AgyEvents{} = state, line), do: AgyEvents.parse_line(state, line)
end
