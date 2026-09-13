defmodule Rail.Runs.Utils.NewEventState do
  @moduledoc false

  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ClaudeEvents
  alias Rail.Tools.Schemas.Backend

  @doc """
  Initializes an event accumulator state struct for either `:claude` or `:agy`.
  """
  def new_event_state(backend, opts \\ [])

  def new_event_state(%Backend{name: :claude}, opts), do: ClaudeEvents.new(opts)
  def new_event_state(%Backend{}, opts), do: AgyEvents.new(opts)
end
