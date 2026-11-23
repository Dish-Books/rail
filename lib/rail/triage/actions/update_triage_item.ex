defmodule Rail.Triage.Actions.UpdateTriageItem do
  @moduledoc false

  import Ecto.Query
  import Rail.Triage.Utils.SettleThread

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  @doc """
  Saves what a person changed on a card, refused while a pass runs, a Send is under way, on a dismissed
  thread, or once the card is closed. Returns `{:ok, item}` as saved.
  """
  def update_triage_item(%Scope{} = scope, %Item{id: id, thread_id: thread_id}, attrs) do
    result =
      Repo.transaction(fn ->
        # The lock a pass's result and Send's close are written under, so an edit never lands inside either.
        thread = Repo.one!(from t in Thread, where: t.id == ^thread_id, lock: "FOR UPDATE")
        item = Repo.get(Item, id)
        changeset = item && Item.draft_changeset(item, attrs)

        cond do
          not Scope.can_access_project?(scope, thread.project_id) -> Repo.rollback(:not_found)
          # A pass can drop the card between the page drawing it and this edit.
          is_nil(item) -> Repo.rollback(:gone)
          changeset.changes == %{} -> item
          is_struct(thread.dismissed_at, DateTime) -> Repo.rollback(:dismissed)
          thread.status == :triaging -> Repo.rollback(:triaging)
          Thread.sending?(thread) -> Repo.rollback(:already_sending)
          Item.closed?(item) -> Repo.rollback(:closed)
          true -> save(changeset)
        end
      end)

    with {:ok, item} <- result do
      {:ok, _thread} = settle_thread(%Thread{id: thread_id})
      {:ok, item}
    end
  end

  defp save(changeset) do
    case Repo.update(changeset) do
      {:ok, item} -> item
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
