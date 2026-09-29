defmodule Rail.Tools.Actions.ListSandboxUsage do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  @gib 1024 ** 3
  # Docker takes a second or two to sample a container, and a slower one is skipped.
  @read_timeout_ms 10_000

  @doc """
  What each running container is using right now: a map of os process id to
  `%{cpus, memory_gb}`, to a tenth. Read only to be shown; the line is walked by
  what is reserved, never by this. A process beside Rail has no reading, nor does
  a container Docker did not answer for.
  """
  def list_sandbox_usage do
    from(p in OsProcess,
      where: p.status in [:starting, :running] and p.runtime == :docker and not is_nil(p.container_id),
      select: {p.id, p.container_id}
    )
    |> Repo.all()
    |> Task.async_stream(
      fn {id, container_id} -> {id, Docker.stats(container_id)} end,
      ordered: false,
      timeout: @read_timeout_ms,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, {:ok, %{} = stats}}}, usage -> Map.put(usage, id, reading(stats))
      _unread_in_time_or_at_all, usage -> usage
    end)
  end

  # CPU is the share of the machine's time it used between Docker's two samples,
  # in CPUs; memory leaves out the page cache the kernel would reclaim first.
  defp reading(%{"cpu_stats" => cpu, "precpu_stats" => precpu, "memory_stats" => memory}) do
    used = cpu["cpu_usage"]["total_usage"] - (precpu["cpu_usage"]["total_usage"] || 0)
    elapsed = cpu["system_cpu_usage"] - (precpu["system_cpu_usage"] || 0)
    cpus = if elapsed > 0, do: used / elapsed * cpu["online_cpus"], else: 0.0
    cache = memory["stats"]["inactive_file"] || memory["stats"]["total_inactive_file"] || 0

    %{cpus: Float.round(cpus, 1), memory_gb: Float.round((memory["usage"] - cache) / @gib, 1)}
  end
end
