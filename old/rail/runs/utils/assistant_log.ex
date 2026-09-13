defmodule Rail.Runs.Utils.AssistantLog do
  @moduledoc false

  import Rail.Runs.Utils.NewEventState
  import Rail.Runs.Utils.ParseLine

  alias Rail.Backends.Schemas.Backend
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

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
  The agent's own words across a run's whole log, oldest first.

  `run_events` holds the raw CLI stream verbatim, so this replays it through the
  backend's parser and then drops everything Rail, the tools or the human put
  there. It is the replacement for the single `output` snapshot a run used
  to store, and it spans every run on that run, chat turns included.
  """
  def assistant_log(%Run{} = run) do
    %Run{role: %Role{backend: %Backend{} = backend}} = run = Repo.preload(run, role: :backend)

    run
    |> Runs.list_run_events()
    |> Enum.reduce(new_event_state(backend), fn event, state ->
      parse_line(state, event.line)
    end)
    |> Map.fetch!(:logs)
    |> Enum.reject(&tagged?/1)
    |> Enum.join("\n")
  end

  defp tagged?(line) when is_binary(line), do: Enum.any?(@markers, &String.starts_with?(line, &1))
  defp tagged?(_other), do: true
end
