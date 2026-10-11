defmodule Rail.Tools.Actions.ParseStream do
  @moduledoc false

  import Rail.Tools.Utils.NewEventState
  import Rail.Tools.Utils.ParseLine

  @doc """
  Reads `lines` a CLI wrote to its stream, oldest first, into that CLI's event
  state.

  `opts` seed the state (`:conversation_id`), or with `:from` name the state an
  earlier call returned, which is read on from rather than started again.
  """
  def parse_stream(cli, lines, opts \\ []) do
    Enum.reduce(lines, opts[:from] || new_event_state(cli, opts), &parse_line(&2, &1))
  end
end
