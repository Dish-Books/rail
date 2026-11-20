defmodule Rail.Triage.Actions.CreateForwardedIssues do
  @moduledoc false

  import Ecto.Query
  import Rail.Triage.Utils.CreateItemIssue
  import Rail.Triage.Utils.SettleThread

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  @doc """
  Create N tickets on a forwarded thread: each open item's issue, with the fields typed on the page that `drafts`
  maps by item id. Returns `{:ok, thread}`, or `{:error, {:not_created, positions}}` after creating the rest.
  """
  def create_forwarded_issues(%Scope{} = scope, %Thread{id: thread_id}, drafts) when is_map(drafts) do
    thread =
      Thread
      |> Repo.get!(thread_id)
      |> Repo.preload([:project, items: from(i in Item, order_by: [asc: i.position, asc: i.id])])

    if Thread.forwarded?(thread) and Scope.can_access_project?(scope, thread.project_id) do
      failed =
        for item <- thread.items,
            Item.issue_draft?(item) and is_nil(item.created_issue_id),
            not created?(scope, thread, item, Map.get(drafts, item.id, %{})),
            do: item.position

      {:ok, thread} = settle_thread(thread)
      if failed == [], do: {:ok, thread}, else: {:error, {:not_created, failed}}
    else
      {:error, :not_found}
    end
  end

  # An item someone else already created counts as created, so a retry or a second tab creates nothing twice.
  defp created?(scope, %Thread{} = thread, %Item{} = item, typed) do
    with {:ok, drafted} <- item |> Item.draft_changeset(typed) |> Ecto.Changeset.apply_action(:update),
         {:ok, _issue} <- create_item_issue(scope, %{item | thread: thread}, drafted) do
      true
    else
      {:error, :already_created} -> true
      {:error, _reason} -> false
    end
  end
end
