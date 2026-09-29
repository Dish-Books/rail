defmodule Rail.Tools.Actions.GetSandboxCapacity do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.LocalCapacity

  alias Rail.Repo
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  What this machine can reserve for sandboxes, and how much of it is reserved now.

  Returns `{:ok, %{cpus, memory_gb, reserved_cpus, reserved_memory_gb}}`. The totals
  are the machine's less the headroom kept for Rail, Postgres and project services;
  `{:error, reason}` when Docker cannot say what the machine has.
  """
  def get_sandbox_capacity do
    with {:ok, cpus, memory_gb} <- machine() do
      {reserved_cpus, reserved_memory_gb} =
        Repo.one(
          from p in OsProcess,
            where: p.status in [:starting, :running],
            select: {coalesce(sum(p.reserved_cpus), 0), coalesce(sum(p.reserved_memory_gb), 0)}
        )

      {:ok,
       %{
         cpus: max(cpus - Rail.sandbox_headroom_cpus(), 0),
         memory_gb: max(memory_gb - Rail.sandbox_headroom_memory_gb(), 0),
         reserved_cpus: reserved_cpus,
         reserved_memory_gb: reserved_memory_gb
       }}
    end
  end

  # The suite runs on a fixed machine of its own, set in config/test.exs.
  defp machine do
    case {Rail.sandbox_runtime(), Rail.local_cpus()} do
      {:docker, _local} ->
        with {:ok, %{"NCPU" => cpus, "MemTotal" => memory}} <- Docker.info() do
          {:ok, cpus, div(memory, 1024 ** 3)}
        end

      {:local, nil} ->
        {cpus, memory_gb} = local_capacity()
        {:ok, cpus, memory_gb}

      {:local, cpus} ->
        {:ok, cpus, Rail.local_memory_gb()}
    end
  end
end
