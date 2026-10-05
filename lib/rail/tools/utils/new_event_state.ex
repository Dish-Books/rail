defmodule Rail.Tools.Utils.NewEventState do
  @moduledoc false

  alias Rail.Tools.AgyEvents
  alias Rail.Tools.ClaudeEvents
  alias Rail.Tools.CommandEvents

  @doc """
  Initializes an event accumulator state struct for either `:claude` or `:agy`,
  or for a shell command's output when given `:command`.
  """
  def new_event_state(cli, opts \\ [])

  def new_event_state(:command, opts), do: CommandEvents.new(opts)
  def new_event_state(:claude, opts), do: ClaudeEvents.new(opts)
  def new_event_state(cli, opts) when is_atom(cli), do: AgyEvents.new(opts)
end
