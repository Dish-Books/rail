defmodule Rail.Tools.Actions.GetSandboxCapacity do
  @moduledoc false

  import Ecto.Query

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
    config = Application.get_env(:rail, :sandbox, [])

    with {:ok, cpus, memory_gb} <- machine(config) do
      {reserved_cpus, reserved_memory_gb} =
        Repo.one(
          from p in OsProcess,
            where: p.status in [:starting, :running],
            select: {coalesce(sum(p.reserved_cpus), 0), coalesce(sum(p.reserved_memory_gb), 0)}
        )

      {:ok,
       %{
         cpus: max(cpus - Keyword.get(config, :headroom_cpus, 0), 0),
         memory_gb: max(memory_gb - Keyword.get(config, :headroom_memory_gb, 0), 0),
         reserved_cpus: reserved_cpus,
         reserved_memory_gb: reserved_memory_gb
       }}
    end
  end

  defp machine(config) do
    case Keyword.get(config, :runtime, :local) do
      :docker ->
        with {:ok, %{"NCPU" => cpus, "MemTotal" => memory}} <- Docker.info() do
          {:ok, cpus, div(memory, 1024 ** 3)}
        end

      :local ->
        {:ok, Keyword.fetch!(config, :local_cpus), Keyword.fetch!(config, :local_memory_gb)}
    end
  end
end
