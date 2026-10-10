defmodule Rail.Tools.Actions.TrustSandboxHostKey do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.EnsureHostConnections

  alias Rail.Repo
  alias Rail.Tools.HostConnection
  alias Rail.Tools.Schemas.SandboxHost

  @doc """
  Trusts `fingerprint`, the key the admin was shown, and reconnects; `{:error,
  :key_not_offered}` when the host offers another now.
  """
  def trust_sandbox_host_key(_scope, %SandboxHost{id: id}, "" <> fingerprint) do
    host = Repo.get!(SandboxHost, id)

    cond do
      # A host that never connected trusts the first key it is offered without being asked.
      is_nil(host.host_key_fingerprint) ->
        {:error, :key_not_offered}

      host.host_key_fingerprint == fingerprint ->
        {:ok, host}

      match?(%{offered: ^fingerprint}, HostConnection.status(id)) ->
        trusted = host.host_key_fingerprint

        # Applied only over the key that was read, so a second click finds the host already trusting it.
        {replaced, _rows} =
          Repo.update_all(
            from(h in SandboxHost, where: h.id == ^id and h.host_key_fingerprint == ^trusted),
            set: [host_key_fingerprint: fingerprint, updated_at: DateTime.utc_now()]
          )

        if replaced == 1 do
          _connections = ensure_host_connections()
          Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
        end

        {:ok, Repo.get!(SandboxHost, id)}

      true ->
        {:error, :key_not_offered}
    end
  end
end
