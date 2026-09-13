defmodule Rail.Runs.Actions.CreateRun do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Runs.Schemas.Run

  @doc """
  Creates a new run record.
  """
  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end
end
