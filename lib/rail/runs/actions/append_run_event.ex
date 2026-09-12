defmodule Rail.Runs.Actions.AppendRunEvent do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  @doc """
  Appends an individual log or transcript line to the run_events table for a run
  and broadcasts it on the run's topic.

  The line belongs to the run rather than to any one of its OS processes: Rail and
  the human write these between turns, and every one carries a marker that keeps it
  out of what the agent itself said.
  """
  def append_run_event(run_or_id, line) do
    run_id =
      case run_or_id do
        %Run{id: id} -> id
        id when is_binary(id) -> id
      end

    event_attrs = %{run_id: run_id, line: line}

    {:ok, event} =
      %RunEvent{}
      |> RunEvent.changeset(event_attrs)
      |> Repo.insert()

    Phoenix.PubSub.broadcast(
      Rail.PubSub,
      "run:#{run_id}",
      {:run_events, run_id, [event]}
    )

    event
  end
end
