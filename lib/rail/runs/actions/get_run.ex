defmodule Rail.Runs.Actions.GetRun do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc """
  Fetches a run by ID.
  """
  def get_run(id) do
    case Repo.get(Run, id) do
      %Run{} = run -> {:ok, run}
      nil -> {:error, :not_found}
    end
  end
end
