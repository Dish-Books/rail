defmodule Rail.Triage.Actions.UpdateTriageDraft do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Item

  @doc """
  Saves a person's edit to an item's drafts, marking the draft they changed as
  theirs. A draft is locked while the item is triaged again, and once accepted.
  """
  def update_triage_draft(%Scope{user: %{id: user_id}}, %Item{id: item_id}, attrs) do
    item = Repo.get!(Item, item_id)
    changeset = Item.draft_changeset(item, attrs, user_id)

    cond do
      item.retriaging -> {:error, :locked}
      is_binary(item.created_issue_id) and issue_changed?(changeset) -> {:error, :locked}
      is_struct(item.reply_posted_at, DateTime) and Ecto.Changeset.changed?(changeset, :reply_text) -> {:error, :locked}
      true -> save(changeset)
    end
  end

  defp save(changeset) do
    with {:ok, item} <- Repo.update(changeset) do
      Phoenix.PubSub.broadcast(Rail.PubSub, "triage", {:triage_changed, item.thread_id})
      {:ok, item}
    end
  end

  defp issue_changed?(changeset) do
    Enum.any?([:issue_title, :issue_description, :issue_priority], &Ecto.Changeset.changed?(changeset, &1))
  end
end
