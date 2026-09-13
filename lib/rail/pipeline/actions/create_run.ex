defmodule Rail.Pipeline.Actions.CreateRun do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc """
  Creates a new run record.
  """
  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end
end
