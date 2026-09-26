defmodule Rail.Triage.Actions.RetriageThread do
  @moduledoc false

  import Ecto.Query
  import Rail.Triage.Utils.EnqueueTriage

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @doc """
  Reads a thread again at a person's asking: after a pass failed, or when they
  think a message Rail passed over does need a response. The messages since
  anyone last replied through Rail are read as new.
  """
  def retriage_thread(%Scope{}, %Thread{id: thread_id}) do
    messages = Repo.all(from m in Message, where: m.thread_id == ^thread_id, order_by: [asc: m.posted_at])
    since_reply = messages |> Enum.reverse() |> Enum.take_while(&(not Message.via_rail?(&1))) |> Enum.map(& &1.id)

    Repo.update_all(from(m in Message, where: m.id in ^since_reply), set: [triaged_at: nil, no_response_reason: nil])

    Thread
    |> Repo.get!(thread_id)
    |> Ecto.Changeset.change(forced: true)
    |> Repo.update!()
    |> enqueue_triage()
  end
end
