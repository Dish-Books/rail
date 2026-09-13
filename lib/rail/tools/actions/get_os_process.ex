defmodule Rail.Tools.Actions.GetOsProcess do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Fetches an os process by ID.
  """
  def get_os_process(id) do
    case Repo.get(OsProcess, id) do
      %OsProcess{} = os_process -> {:ok, os_process}
      nil -> {:error, :not_found}
    end
  end
end
