defmodule Rail.Runs.Actions.AppendRunEvent do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent

  @doc """
  Appends an individual log or transcript line to the run_events table for a run,
  maintaining sequential ordering and broadcasting to PubSub subscribers.
  """
  def append_run_event(run_or_id, line) do
    run_id =
      case run_or_id do
        %Run{id: id} -> id
        id when is_binary(id) -> id
      end

    max_seq =
      Repo.one(
        from e in RunEvent,
          where: e.run_id == ^run_id,
          select: max(e.seq)
      ) || 0

    now = DateTime.utc_now()

    event_attrs = %{
      run_id: run_id,
      seq: max_seq + 1,
      line: line,
      inserted_at: now,
      updated_at: now
    }

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
