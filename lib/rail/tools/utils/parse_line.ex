defmodule Rail.Tools.Utils.ParseLine do
  @moduledoc false

  alias Rail.Tools.AgyEvents
  alias Rail.Tools.ClaudeEvents
  alias Rail.Tools.CommandEvents

  @doc """
  Parses a raw line from an agent NDJSON stdout stream into the accumulator state.
  """
  def parse_line(%ClaudeEvents{} = state, line), do: ClaudeEvents.parse_line(state, line)
  def parse_line(%AgyEvents{} = state, line), do: AgyEvents.parse_line(state, line)
  def parse_line(%CommandEvents{} = state, line), do: CommandEvents.parse_line(state, line)
end
