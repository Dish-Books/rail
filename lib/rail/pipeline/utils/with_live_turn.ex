defmodule Rail.Pipeline.Utils.WithLiveTurn do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Runs `fun` for the turn `os_process` carries, while it is still live, and
  returns what `fun` does, or `:ended` once the turn is over.

  An agent's CLI can send one tool call twice, the second while the first is
  still ending the turn. Calls from one turn take turns here, and the stop that
  ends it marks the row finished before letting go, so the repeat finds the turn
  over and does nothing a second time.
  """
  def with_live_turn(%OsProcess{id: id}, fun) when is_binary(id) and is_function(fun, 0) do
    :global.trans(
      {{__MODULE__, id}, self()},
      fn ->
        case Repo.get(OsProcess, id) do
          %OsProcess{status: status} when status in [:starting, :running] -> fun.()
          _ended -> :ended
        end
      end,
      [node()],
      :infinity
    )
  end
end
