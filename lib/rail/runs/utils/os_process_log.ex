defmodule Rail.Runs.Utils.OsProcessLog do
  @moduledoc false

  import Ecto.Query

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  # Everything Rail, the tools or the human contributed carries one of these
  # markers; what the agent said carries none.
  @markers [
    "[tool]",
    "[tool error]",
    "[init]",
    "[result]",
    "[denied]",
    "[recovered]",
    "[rate limit]",
    "[rail]",
    "[human]",
    "[handoff]",
    "[stderr]",
    "[error]"
  ]

  @doc """
  The agent's own words for one OS process, oldest first.

  `run_events` is the run's whole log across every process it spawned, so this
  reads only from the seq that process started at. That is what makes a question
  asked in this turn distinguishable from the same question asked, and answered,
  two turns ago.
  """
  def os_process_log(%OsProcess{} = os_process) do
    os_process = Repo.preload(os_process, run: [role: :backend])

    case os_process.run do
      %Run{} = run ->
        os_process.run_id
        |> events_from(os_process.start_seq)
        |> Enum.reduce(Runs.new_event_state(backend_for(run)), fn event, state ->
          Runs.parse_line(state, event.line)
        end)
        |> Map.fetch!(:logs)
        |> Enum.reject(&tagged?/1)
        |> Enum.join("\n")

      nil ->
        ""
    end
  end

  defp events_from(run_id, start_seq) do
    Repo.all(
      from e in RunEvent,
        where: e.run_id == ^run_id and e.seq >= ^start_seq,
        order_by: [asc: e.seq]
    )
  end

  defp backend_for(%Run{role: %{backend: %Backend{} = backend}}), do: backend
  defp backend_for(_unconfigured), do: %Backend{name: :claude}

  defp tagged?(line) when is_binary(line), do: Enum.any?(@markers, &String.starts_with?(line, &1))
  defp tagged?(_other), do: true
end
