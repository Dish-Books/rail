defmodule Rail.Triage.Utils.EnqueueTriage do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Triage.Schemas.Thread

  @doc """
  Marks `thread` as being triaged and tells `Rail.Triage.Runner` a pass is owed,
  after `:delay` milliseconds. The status is what the runner recovers from, so a
  pass announced while it was down is still run.
  """
  def enqueue_triage(%Thread{} = thread, opts \\ []) do
    {:ok, thread} = thread |> Ecto.Changeset.change(status: :triaging, error: nil) |> Repo.update()
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_scheduled, thread.id, Keyword.get(opts, :delay, 0)})
    Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, thread.id})
    {:ok, thread}
  end
end
