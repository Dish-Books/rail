defmodule Rail.Triage.Utils.CreateItemIssue do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Thread

  @doc """
  Creates an item's issue as `drafted`, records it on the item and links it back to the thread.
  Two people accepting at once create one issue. Needs the item's thread and project preloaded.
  """
  def create_item_issue(%Scope{user: %{id: user_id}} = scope, %Item{thread: %Thread{}} = item, %Item{} = drafted) do
    with :ok <- claim(item, user_id),
         {:ok, %Issue{} = issue} <- create(scope, item, drafted) do
      # The ticket points back at where it was reported.
      if item.thread.permalink,
        do: {:ok, _job} = Issues.link_url(issue, item.thread.permalink, Thread.link_label(item.thread))

      {:ok, issue}
    end
  end

  defp claim(%Item{id: item_id}, user_id) do
    case Repo.update_all(from(i in Item, where: i.id == ^item_id and is_nil(i.issue_created_by_id)),
           set: [issue_created_by_id: user_id]
         ) do
      {1, _claimed} -> :ok
      {0, _taken} -> {:error, :already_created}
    end
  end

  # The item keeps the issue as it was created, which is what the person sent.
  defp create(scope, %Item{id: item_id, thread: thread} = item, %Item{} = drafted) do
    attrs = %{
      title: drafted.issue_title,
      description: drafted.issue_description,
      priority: drafted.issue_priority,
      estimate: drafted.issue_estimate
    }

    case Issues.create_issue(scope, thread.project, attrs) do
      {:ok, %Issue{} = issue} ->
        item
        |> Ecto.Changeset.change(
          created_issue_id: issue.id,
          issue_title: attrs.title,
          issue_description: attrs.description,
          issue_priority: attrs.priority,
          issue_estimate: attrs.estimate
        )
        |> Repo.update!()

        {:ok, issue}

      {:error, reason} ->
        Repo.update_all(from(i in Item, where: i.id == ^item_id), set: [issue_created_by_id: nil])
        {:error, reason}
    end
  end
end
