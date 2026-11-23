defmodule Rail.Triage.Actions.UpdateTriageReply do
  @moduledoc false

  import Ecto.Query
  import Rail.Triage.Utils.SettleThread

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Thread

  @doc """
  Saves the reply as typed, refused while a pass runs, a Send is under way, once it is posted, or once dismissed.
  """
  def update_triage_reply(%Scope{} = scope, %Thread{id: id}, attrs) do
    result =
      Repo.transaction(fn ->
        # The lock a pass's result and Send's close are written under, so an edit never lands inside either.
        thread = Repo.one!(from t in Thread, where: t.id == ^id, lock: "FOR UPDATE")
        changeset = Thread.reply_changeset(thread, attrs)

        cond do
          not Scope.can_access_project?(scope, thread.project_id) -> Repo.rollback(:not_found)
          # A reconnect's form recovery sends back the reply as it stands, "" where the box is empty.
          same_reply?(thread, changeset) -> thread
          Thread.forwarded?(thread) -> Repo.rollback(:forwarded)
          is_struct(thread.dismissed_at, DateTime) -> Repo.rollback(:dismissed)
          thread.status == :triaging -> Repo.rollback(:triaging)
          Thread.sending?(thread) -> Repo.rollback(:already_sending)
          is_struct(thread.reply_posted_at, DateTime) -> Repo.rollback(:already_sent)
          true -> Repo.update!(changeset)
        end
      end)

    with {:ok, _thread} <- result, do: settle_thread(%Thread{id: id})
  end

  defp same_reply?(%Thread{reply_text: stored}, changeset),
    do: (stored || "") == (Ecto.Changeset.get_field(changeset, :reply_text) || "")
end
