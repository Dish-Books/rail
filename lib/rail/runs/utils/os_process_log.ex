defmodule Rail.Runs.Utils.OsProcessLog do
  @moduledoc false

  import Ecto.Query
  import Rail.Runs.Utils.NewEventState
  import Rail.Runs.Utils.ParseLine

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo
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
  reads only the lines that carry this process. That is what makes a question
  asked in this turn distinguishable from the same question asked, and answered,
  two turns ago.
  """
  def os_process_log(%OsProcess{} = os_process) do
    os_process = Repo.preload(os_process, run: [role: :backend])

    case os_process.run do
      %Run{} = run ->
        os_process.id
        |> events_from()
        |> Enum.reduce(new_event_state(backend_for(run)), fn event, state ->
          parse_line(state, event.line)
        end)
        |> Map.fetch!(:logs)
        |> Enum.reject(&tagged?/1)
        |> Enum.join("\n")

      nil ->
        ""
    end
  end

  defp events_from(os_process_id) do
    Repo.all(
      from e in RunEvent,
        where: e.os_process_id == ^os_process_id,
        order_by: [asc: e.seq]
    )
  end

  defp backend_for(%Run{role: %{backend: %Backend{} = backend}}), do: backend
  defp backend_for(_unconfigured), do: %Backend{name: :claude}

  defp tagged?(line) when is_binary(line), do: Enum.any?(@markers, &String.starts_with?(line, &1))
  defp tagged?(_other), do: true
end
