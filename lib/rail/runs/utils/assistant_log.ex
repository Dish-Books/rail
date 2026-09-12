defmodule Rail.Runs.Utils.AssistantLog do
  @moduledoc false

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  # Everything Rail, the tools or the human contributed carries one of these
  # markers; what the agent said carries none.
  @markers ~w([tool] [tool error] [init] [result] [denied] [recovered] [rate limit] [rail] [human] [handoff] [stderr] [error])

  @doc """
  The agent's own words across a run's whole log, oldest first.

  `run_events` holds the raw CLI stream verbatim, so this replays it through the
  backend's parser and then drops everything Rail, the tools or the human put
  there. It is the replacement for the single `output` snapshot a run used
  to store, and it spans every run on that run, chat turns included.
  """
  def assistant_log(%Run{} = run) do
    run = Repo.preload(run, role: :backend)

    run.id
    |> Runs.list_run_events()
    |> Enum.reduce(Runs.new_event_state(backend_for(run)), fn event, state ->
      Runs.parse_line(state, event.line)
    end)
    |> Map.fetch!(:logs)
    |> Enum.reject(&tagged?/1)
    |> Enum.join("\n")
  end

  def assistant_log(run_id) when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      %Run{} = run -> assistant_log(run)
      nil -> ""
    end
  end

  def assistant_log(_other), do: ""

  defp backend_for(%Run{role: %{backend: %Backend{} = backend}}), do: backend
  defp backend_for(_unconfigured), do: %Backend{name: :claude}

  defp tagged?(line) when is_binary(line), do: Enum.any?(@markers, &String.starts_with?(line, &1))
  defp tagged?(_other), do: true
end
