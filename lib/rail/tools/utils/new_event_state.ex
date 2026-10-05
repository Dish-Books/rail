defmodule Rail.Tools.Utils.NewEventState do
  @moduledoc false

  alias Rail.Tools.ClaudeEvents
  alias Rail.Tools.CommandEvents
  alias Rail.Tools.Schemas.Backend

  @doc """
  Initializes an event accumulator state struct for a backend's agent stream,
  or for a shell command's output when given `:command`.
  """
  def new_event_state(backend, opts \\ [])

  def new_event_state(:command, opts), do: CommandEvents.new(opts)

  def new_event_state(%Backend{}, opts), do: ClaudeEvents.new(opts)
end
