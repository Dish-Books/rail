defmodule Rail.Tools.Actions.ParseStream do
  @moduledoc false

  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine

  @doc """
  Reads `lines` a backend's CLI wrote to its stream, oldest first, into that
  backend's event state.

  `opts` seed the state (`:task_id`, `:role_id`, `:conversation_id`), so questions
  detected along the way are attributed to the run they were asked in.
  """
  def parse_stream(backend, lines, opts \\ []) do
    Enum.reduce(lines, new_event_state(backend, opts), &parse_line(&2, &1))
  end
end
