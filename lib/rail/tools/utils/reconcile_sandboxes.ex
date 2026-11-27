defmodule Rail.Tools.Utils.ReconcileSandboxes do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.StopSandbox

  alias Rail.Repo
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Sandbox

  @label "dev.railai.task-sandbox"

  @doc """
  Brings tasks' sandboxes in line with Docker: a sandbox whose container is gone is stopped, keeping its disk; a
  container no live sandbox owns is removed; and a container that has run nothing for `Rail.sandbox_idle_minutes/0` is
  stopped. A Docker that cannot be listed changes nothing. Returns `:ok`.
  """
  def reconcile_sandboxes(now \\ DateTime.utc_now()) do
    with :docker <- Rail.sandbox_runtime(),
         {:ok, containers} <- Docker.list_containers(@label) do
      ours = Enum.filter(containers, &Map.has_key?(&1["Labels"] || %{}, @label))
      running = for %{"Id" => id, "State" => "running"} <- ours, into: MapSet.new(), do: id
      live = Repo.all(from s in Sandbox, where: s.status in [:starting, :running])
      owned = MapSet.new(live, & &1.container_id)

      for %{"Id" => id} <- ours, not MapSet.member?(owned, id), do: Docker.remove_container(id, force: true)

      for %Sandbox{} = sandbox <- live do
        cond do
          not MapSet.member?(running, sandbox.container_id) -> gone(sandbox)
          idle?(sandbox, now) -> stop_sandbox(sandbox)
          true -> :ok
        end
      end
    end

    :ok
  end

  # Its processes' Followers see the container gone and settle them; what is left is only to say so.
  defp gone(%Sandbox{container_id: id} = sandbox) do
    if is_binary(id), do: Docker.remove_container(id, force: true)

    sandbox
    |> Sandbox.changeset(%{status: :stopped, container_id: nil, token_hash: nil, stopped_at: DateTime.utc_now()})
    |> Repo.update!()
  end

  defp idle?(%Sandbox{id: id} = sandbox, now) do
    {live, last_ended} =
      Repo.one(
        from p in OsProcess,
          where: p.sandbox_id == ^id,
          select: {p.id |> count() |> filter(p.status in [:waiting_for_resources, :starting, :running]), max(p.ended_at)}
      )

    since =
      [last_ended, sandbox.ready_at, sandbox.started_at] |> Enum.reject(&is_nil/1) |> Enum.max(DateTime, fn -> now end)

    live == 0 and DateTime.diff(now, since, :second) >= Rail.sandbox_idle_minutes() * 60
  end
end
