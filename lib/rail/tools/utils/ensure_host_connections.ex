defmodule Rail.Tools.Utils.EnsureHostConnections do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.HostConnection
  alias Rail.Tools.Schemas.SandboxHost

  @supervisor Rail.Tools.HostSupervisor
  @registry Rail.Tools.HostRegistry

  @doc """
  Under Docker, runs one connection per host not removed, restarting any started
  with another address or trusted key and stopping a removed host's.
  """
  def ensure_host_connections do
    case Rail.sandbox_runtime() do
      :docker -> reconcile()
      :local -> []
    end
  end

  defp reconcile do
    running =
      for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(@supervisor),
          is_pid(pid),
          host_id <- Registry.keys(@registry, pid),
          into: %{},
          do: {host_id, pid}

    # Removal stamps the row rather than deleting it, so a removed host is always found.
    removed =
      Repo.all(from h in SandboxHost, where: h.id in ^Map.keys(running) and not is_nil(h.removed_at), select: h.id)

    for host_id <- removed, do: DynamicSupervisor.terminate_child(@supervisor, running[host_id])

    hosts = Repo.all(from h in SandboxHost, where: is_nil(h.removed_at), order_by: [asc: h.inserted_at, asc: h.id])
    Enum.map(hosts, &ensure(&1, running[&1.id]))
  end

  defp ensure(host, nil), do: start(host)

  defp ensure(host, pid) do
    case HostConnection.status(host.id) do
      # The connection records the first key it sees itself, so only a different trusted key is stale.
      %{address: address, trusted: trusted}
      when address == host.ssh_address and (is_nil(trusted) or trusted == host.host_key_fingerprint) ->
        {:ok, pid}

      _stale_or_gone ->
        DynamicSupervisor.terminate_child(@supervisor, pid)
        start(host)
    end
  end

  defp start(host) do
    case DynamicSupervisor.start_child(@supervisor, {HostConnection, host}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end
