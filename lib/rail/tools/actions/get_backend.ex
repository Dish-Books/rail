defmodule Rail.Tools.Actions.GetBackend do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Tools.Schemas.Backend

  def get_backend(id) do
    case Repo.get(Backend, id) do
      %Backend{} = backend -> {:ok, backend}
      nil -> {:error, :backend_not_found}
    end
  end
end
