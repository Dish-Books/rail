defmodule Rail.Tools.Actions.ListSandboxHostStatuses do
  @moduledoc false

  alias Rail.Tools
  alias Rail.Tools.HostConnection

  @doc """
  What the Hosts tab shows for each host, Rail's machine first with a nil `host`.
  Under the local runtime every extra host is `:inactive`.
  """
  def list_sandbox_host_statuses do
    [rails_machine() | Enum.map(Tools.list_sandbox_hosts(), &extra_host/1)]
  end

  defp rails_machine do
    {browser_cpus, browser_memory_gb} =
      if Rail.sandbox_runtime() == :docker, do: {Rail.browser_cpus(), Rail.browser_memory_gb()}, else: {0, 0}

    figures =
      case Tools.get_sandbox_capacity() do
        {:ok, %{cpus: cpus, memory_gb: memory_gb}} ->
          %{
            cpus: cpus,
            cpus_total: cpus + Rail.sandbox_headroom_cpus() + browser_cpus,
            memory_gb: memory_gb,
            memory_gb_total: memory_gb + Rail.sandbox_headroom_memory_gb() + browser_memory_gb
          }

        {:error, _unreadable} ->
          %{cpus: nil, cpus_total: nil, memory_gb: nil, memory_gb_total: nil}
      end

    Map.merge(
      %{host: nil, state: :connected, since: nil, error: nil, trusted: nil, offered: nil, image: :current},
      figures
    )
  end

  defp extra_host(host) do
    status = HostConnection.status(host.id) || %{state: :connecting, since: nil, error: nil, offered: nil}

    state =
      cond do
        Rail.sandbox_runtime() == :local -> :inactive
        is_nil(host.host_key_fingerprint) and status.state != :connected -> :never_connected
        true -> status.state
      end

    # Figures are what the host had when last connected; an unreachable host keeps them, greyed.
    machine = if state in [:connected, :unreachable], do: status[:machine]

    %{
      host: host,
      state: state,
      since: status.since,
      error: status.error,
      trusted: host.host_key_fingerprint,
      offered: if(state == :unreachable and status.offered != host.host_key_fingerprint, do: status.offered),
      image: if(state in [:connected, :unreachable], do: status[:image]),
      cpus: machine && max(machine.cpus - Rail.sandbox_headroom_cpus(), 0),
      cpus_total: machine && machine.cpus,
      memory_gb: machine && max(machine.memory_gb - Rail.sandbox_headroom_memory_gb(), 0),
      memory_gb_total: machine && machine.memory_gb
    }
  end
end
