defmodule Rail.Pipeline.Actions.AppendRunEvents do
  @moduledoc false

  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Repo

  @doc """
  Appends a batch of lines one OS process wrote to its run's log, in order, and
  broadcasts them on the run's topic.

  `seq` is left to the database: it orders the run's whole log, and the process
  writing these is not the only writer appending to it. Returns the inserted
  entries; an empty batch writes and broadcasts nothing.
  """
  def append_run_events(_run_id, _os_process_id, []), do: []

  def append_run_events(run_id, os_process_id, lines) do
    now = DateTime.utc_now()

    entries =
      Enum.map(lines, fn line ->
        %{
          id: UXID.generate!(),
          run_id: run_id,
          os_process_id: os_process_id,
          line: line,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(RunEvent, entries)
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_events, run_id, entries})
    entries
  end
end
