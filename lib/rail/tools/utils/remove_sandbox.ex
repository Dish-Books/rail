defmodule Rail.Tools.Utils.RemoveSandbox do
  @moduledoc false

  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Removes a settled process's container, once nothing is left to read from it.
  A process that ran beside Rail has none.
  """
  def remove_sandbox(%OsProcess{runtime: :docker, container_id: id}) when is_binary(id) do
    _removed = Docker.remove_container(id)
    :ok
  end

  def remove_sandbox(%OsProcess{}), do: :ok
end
