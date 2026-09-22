defmodule Rail.Tools.CommandEvents do
  @moduledoc """
  The event state for a shell command's output, which has nothing in it to parse.

  A command reports how it went with its exit status alone, so this carries the
  fields the Follower reads off an agent's state, left empty.
  """

  defstruct [:conversation_id, :result_error, logs: [], usage: nil, saw_result: false]

  @doc "Initializes the state for a command's stream."
  def new(_opts \\ []), do: %__MODULE__{}

  @doc "A command's lines are read as they were written, so there is nothing to accumulate."
  def parse_line(%__MODULE__{} = state, _line), do: state
end
