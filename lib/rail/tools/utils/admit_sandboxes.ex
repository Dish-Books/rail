defmodule Rail.Tools.Utils.AdmitSandboxes do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.LaunchSandbox

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  require Logger

  @doc """
  Starts waiting sandboxes, oldest first, for as long as the one at the front of
  the line fits in what is unreserved. A younger one never starts ahead of an
  older one, even when it would fit. An agent whose backend is signed out is
  passed over and keeps its place: it would only start to fail, so it waits for
  someone to sign the backend in, and holds nobody behind it up meanwhile.

  One pass at a time on this machine, so two never hand out the same CPU. It must
  run outside any transaction, so it sees only committed rows. `:own` names a row
  whose caller settles its own failure to start; left waiting, its run is marked
  waiting in the same pass, so a later one that starts it finds the run to flip.
  Returns each row it tried to start, mapped to what `launch_sandbox/1` said.
  """
  def admit_sandboxes(opts \\ []) do
    own = Keyword.get(opts, :own)
    results = :global.trans({:rail_sandbox_admission, self()}, fn -> admit(own) end)
    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    results
  end

  # A pass that cannot read the machine admits nothing; the next pass tries again.
  defp admit(own) do
    case Tools.get_sandbox_capacity() do
      {:ok, capacity} ->
        free = %{
          cpus: capacity.cpus - capacity.reserved_cpus,
          memory_gb: capacity.memory_gb - capacity.reserved_memory_gb
        }

        waiting =
          Repo.all(
            from p in OsProcess,
              where: p.status == :waiting_for_resources,
              order_by: [asc: p.queued_at, asc: p.id],
              preload: [run: [role: :backend]]
          )

        {_free, results} = Enum.reduce_while(waiting, {free, %{}}, &admit_next(&1, &2, capacity, own))
        mark_waiting(Enum.find(waiting, &(&1.id == own)), results)
        results

      {:error, reason} ->
        Logger.warning("No sandbox was started, because the machine's capacity could not be read: #{inspect(reason)}")
        if own, do: OsProcess |> Repo.get(own) |> Repo.preload(:run) |> mark_waiting(%{})
        %{}
    end
  end

  defp admit_next(%OsProcess{} = os_process, {free, results}, capacity, own) do
    cond do
      held?(os_process) ->
        {:cont, {free, results}}

      os_process.reserved_cpus > capacity.cpus or os_process.reserved_memory_gb > capacity.memory_gb ->
        {:cont, {free, Map.put(results, os_process.id, refuse(os_process, capacity, own))}}

      OsProcess.short_of(os_process, free) == %{cpus: 0, memory_gb: 0} ->
        result = launch(os_process, capacity, own)
        {:cont, {taken(free, os_process, result), Map.put(results, os_process.id, result)}}

      true ->
        {:halt, {free, results}}
    end
  end

  defp held?(%OsProcess{kind: :agent, run: %Run{role: %Role{backend: %Backend{status: :signed_out}}}}), do: true
  defp held?(_os_process), do: false

  defp mark_waiting(%OsProcess{id: id, status: :waiting_for_resources, run: %Run{} = run}, results)
       when not is_map_key(results, id) do
    {:ok, _waiting} = Pipeline.update_run(run, %{status: :waiting_for_resources})
  end

  defp mark_waiting(_started_or_none, _results), do: :ok

  defp launch(%OsProcess{} = os_process, capacity, own) do
    case launch_sandbox(os_process, capacity) do
      {:ok, %OsProcess{run: %Run{status: :waiting_for_resources} = run}} = launched ->
        {:ok, _running} = Pipeline.update_run(run, %{status: :running})
        Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})
        launched

      {:ok, _os_process} = launched ->
        launched

      {:error, reason} when os_process.id == own ->
        {:error, reason}

      {:error, reason} ->
        settle(os_process, "Could not start its sandbox: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Possible only when headroom was raised after the role was saved, and a
  # reservation that can never fit would otherwise hold the line forever.
  defp refuse(%OsProcess{} = os_process, capacity, own) do
    error =
      "It needs #{os_process.reserved_cpus} CPUs and #{os_process.reserved_memory_gb} GB, and this machine has " <>
        "#{capacity.cpus} CPUs and #{capacity.memory_gb} GB to reserve, so it could never start."

    failed =
      os_process
      |> OsProcess.changeset(%{
        status: :failed,
        ended_reason: :failed_to_start,
        ended_at: DateTime.utc_now(),
        exit_code: -1,
        launch: nil
      })
      |> Repo.update!()

    if os_process.id != own, do: settle(failed, error)

    {:error, error}
  end

  defp settle(%OsProcess{run_id: run_id} = os_process, error) do
    {:ok, _run} = Pipeline.run_finished(%{os_process | status: :failed}, %{exit_code: -1, error: error})
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_changed, run_id})
  end

  # A process that started, or failed after starting, holds its reservation.
  defp taken(free, %OsProcess{id: id} = os_process, result) do
    if match?({:ok, _started}, result) or Repo.get!(OsProcess, id).status == :running,
      do: %{cpus: free.cpus - os_process.reserved_cpus, memory_gb: free.memory_gb - os_process.reserved_memory_gb},
      else: free
  end
end
