defmodule Rail.Tools.Actions.ParseStream do
  @moduledoc false

  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine

  @doc """
  Reads `lines` a CLI wrote to its stream, oldest first, into that CLI's event
  state.

  `opts` seed the state (`:conversation_id`).
  """
  def parse_stream(cli, lines, opts \\ []) do
    Enum.reduce(lines, new_event_state(cli, opts), &parse_line(&2, &1))
  end
end
