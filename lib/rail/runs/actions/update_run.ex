defmodule Rail.Runs.Actions.UpdateRun do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc """
  Updates a run record.
  """
  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end
end
