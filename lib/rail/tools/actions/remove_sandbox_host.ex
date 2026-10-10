defmodule Rail.Tools.Actions.RemoveSandboxHost do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.EnsureHostConnections

  alias Rail.Repo
  alias Rail.Tools.Schemas.SandboxHost

  @doc """
  Stamps a host removed and closes its connection. The row stays, so what ran
  on the host can still name it; removing it again changes nothing.
  """
  def remove_sandbox_host(_scope, %SandboxHost{id: id}) do
    now = DateTime.utc_now()

    {removed, _rows} =
      Repo.update_all(from(h in SandboxHost, where: h.id == ^id and is_nil(h.removed_at)),
        set: [removed_at: now, updated_at: now]
      )

    if removed == 1 do
      _connections = ensure_host_connections()
      Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    end

    {:ok, Repo.get!(SandboxHost, id)}
  end
end
