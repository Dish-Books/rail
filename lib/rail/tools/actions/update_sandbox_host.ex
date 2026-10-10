defmodule Rail.Tools.Actions.UpdateSandboxHost do
  @moduledoc false

  import Rail.Tools.Utils.EnsureHostConnections

  alias Rail.Repo
  alias Rail.Tools.Schemas.SandboxHost

  @doc "Saves a host's name and address; a new address restarts its connection."
  def update_sandbox_host(_scope, %SandboxHost{} = host, attrs) do
    with {:ok, updated} <- host |> SandboxHost.changeset(attrs) |> Repo.update() do
      _connections = ensure_host_connections()
      Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
      {:ok, updated}
    end
  end
end
