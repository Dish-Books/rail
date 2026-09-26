defmodule Rail.Triage.Utils.EnqueueTriage do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Triage.Schemas.Thread
  alias Rail.Triage.Workers.TriageThread

  @doc """
  Marks `thread` as being triaged and schedules a pass. A pass already waiting
  to run absorbs this one, so a burst of messages is read once.
  """
  def enqueue_triage(%Thread{} = thread, opts \\ []) do
    {:ok, thread} = thread |> Ecto.Changeset.change(status: :triaging, error: nil) |> Repo.update()
    {:ok, _job} = %{thread_id: thread.id} |> TriageThread.new(opts) |> Oban.insert()
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, thread.id})
    {:ok, thread}
  end
end
