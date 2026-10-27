defmodule Rail.Tools.Actions.GetSandboxCapacity do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.LocalCapacity
  import Rail.Tools.Utils.UsedMemory

  alias Rail.Repo
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Types.Cpus

  @doc """
  What this machine can reserve for sandboxes, how much of it is reserved now,
  and how its memory stands.

  Returns `{:ok, %{cpus, reserved_cpus, memory_gb, used_memory_gb}}`. The CPUs are
  the machine's less the headroom kept for Rail, Postgres and project services
  and, under Docker, what the shared browser's container is given. Memory is not
  reserved: `memory_gb` is all the machine has and `used_memory_gb` what is in use
  on it now, by anything, or `nil` when that cannot be read. `{:error, reason}`
  when Docker cannot say what the machine has.
  """
  def get_sandbox_capacity do
    with {:ok, cpus, memory_gb, used_memory_gb} <- machine() do
      reserved_cpus =
        Repo.one(
          from p in OsProcess,
            where: p.status in [:starting, :running],
            select: type(coalesce(sum(p.reserved_cpus), 0), Cpus)
        )

      {:ok,
       %{
         cpus: max(cpus - Rail.sandbox_headroom_cpus() - browser_cpus(), 0),
         reserved_cpus: reserved_cpus,
         memory_gb: memory_gb,
         used_memory_gb: used_memory_gb
       }}
    end
  end

  # Only a container holds Chrome to its share; beside Rail it takes what it uses.
  defp browser_cpus do
    case Rail.sandbox_runtime() do
      :docker -> Rail.browser_cpus()
      :local -> 0
    end
  end

  # The suite runs on a fixed machine of its own, set in config/test.exs.
  defp machine do
    case {Rail.sandbox_runtime(), Rail.local_cpus()} do
      {:docker, _local} ->
        with {:ok, %{"NCPU" => cpus, "MemTotal" => memory}} <- Docker.info() do
          {:ok, cpus, div(memory, 1024 ** 3), used_memory()}
        end

      {:local, nil} ->
        {cpus, memory_gb} = local_capacity()
        {:ok, cpus, memory_gb, used_memory()}

      {:local, cpus} ->
        {:ok, cpus, Rail.local_memory_gb(), nil}
    end
  end
end
