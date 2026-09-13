defmodule Rail.Pipeline.Actions.AppendRunEvent do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Repo

  @doc """
  Appends an individual log or transcript line to the run_events table for a run
  and broadcasts it on the run's topic.

  The line belongs to the run rather than to any one of its OS processes: Rail and
  the human write these between turns, and every one carries a marker that keeps it
  out of what the agent itself said.
  """
  def append_run_event(%Run{id: run_id}, line) do
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
