defmodule Rail.Tools.Utils.EnqueueSandbox do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.AdmitSandboxes

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Puts `os_process` in line for the sandbox `spec` describes, holding what its
  run's role reserves, and starts it at once if it fits.

  Returns `{:ok, os_process}` once it runs, `{:waiting, os_process}` with its run
  marked waiting and a line in its log saying what it waits for, or
  `{:error, reason}` when it could not be started.
  """
  def enqueue_sandbox(%OsProcess{} = os_process, %Run{role: %Role{} = role} = run, spec) when is_map(spec) do
    queued =
      os_process
      |> OsProcess.changeset(%{
        status: :waiting_for_resources,
        runtime: Keyword.get(Application.get_env(:rail, :sandbox, []), :runtime, :local),
        reserved_cpus: role.reserved_cpus,
        reserved_memory_gb: role.reserved_memory_gb,
        queued_at: DateTime.utc_now(),
        launch: Jason.encode!(spec)
      })
      |> Repo.update!()

    results = admit_sandboxes(own: queued.id)
    current = Repo.get!(OsProcess, queued.id)

    cond do
      Map.has_key?(results, queued.id) -> results[queued.id]
      current.status == :waiting_for_resources -> {:waiting, announce(current, run)}
      # coveralls-ignore-next-line (another pass started it between the two, which no test can time)
      true -> {:ok, current}
    end
  end

  defp announce(%OsProcess{} = os_process, %Run{} = run) do
    {:ok, %{position: position}} = Tools.get_queue_position(run)

    line =
      "[rail] #{label(os_process)} needs #{cpus(os_process.reserved_cpus)} and #{os_process.reserved_memory_gb} GB, " <>
        "and #{reason(os_process, Tools.get_sandbox_capacity())}. " <>
        "It is #{ordinal(position)} in line and starts on its own as soon as enough is free."

    Pipeline.append_run_events(run.id, os_process.id, [line])
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})
    os_process
  end

  defp label(%OsProcess{kind: :setup}), do: "Worktree setup"
  defp label(%OsProcess{kind: :ci}), do: "CI"

  # A turn is numbered among its run's agent turns, as the conversation numbers it.
  defp label(%OsProcess{kind: :agent} = os_process) do
    turn =
      Repo.aggregate(
        from(p in OsProcess,
          where: p.run_id == ^os_process.run_id and p.kind == :agent and p.inserted_at <= ^os_process.inserted_at
        ),
        :count
      )

    "Turn #{turn}"
  end

  defp reason(%OsProcess{} = os_process, {:ok, capacity}) do
    free = %{
      cpus: max(capacity.cpus - capacity.reserved_cpus, 0),
      memory_gb: max(capacity.memory_gb - capacity.reserved_memory_gb, 0)
    }

    case OsProcess.short_of(os_process, free) do
      %{cpus: 0, memory_gb: 0} -> "the runs ahead of it in line get what is free first"
      %{cpus: 0} -> memory_free(free.memory_gb)
      %{memory_gb: 0} -> cpus_free(free.cpus)
      _both -> "#{cpus_free(free.cpus)} and #{memory_free(free.memory_gb)}"
    end
  end

  defp reason(%OsProcess{}, {:error, _reason}), do: "Rail could not read what this machine has free"

  defp cpus_free(0), do: "every CPU on this machine is reserved"
  defp cpus_free(free), do: "only #{cpus(free)} on this machine #{if free == 1, do: "is", else: "are"} free"

  defp memory_free(0), do: "all of this machine's memory is reserved"
  defp memory_free(free), do: "only #{free} GB of this machine's memory is free"

  defp cpus(count), do: if(count == 1, do: "1 CPU", else: "#{count} CPUs")

  # 11th, 12th and 13th, whatever their last digit says.
  defp ordinal(position) do
    suffix =
      if rem(position, 100) in 11..13,
        do: "th",
        else: Map.get(%{1 => "st", 2 => "nd", 3 => "rd"}, rem(position, 10), "th")

    "#{position}#{suffix}"
  end
end
