defmodule Rail.Pipeline.Actions.UpdateRun do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Updates a run record.
  """
  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end
end
