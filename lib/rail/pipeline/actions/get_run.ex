defmodule Rail.Pipeline.Actions.GetRun do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

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
