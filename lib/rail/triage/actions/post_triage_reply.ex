defmodule Rail.Triage.Actions.PostTriageReply do
  @moduledoc false

  import Rail.Triage.Utils.CanLinkIssue
  import Rail.Triage.Utils.CanPostToSlack
  import Rail.Triage.Utils.ClaimReply
  import Rail.Triage.Utils.PostToSlack
  import Rail.Triage.Utils.ReleaseReply
  import Rail.Triage.Utils.SettleThread
  import Rail.Triage.Utils.SlackIssueLink

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Item

  @doc """
  Posts an item's reply, with the person's edits, in the thread as them. A reply
  that links its issue waits until the issue exists, and one someone else is
  already posting is not posted again.
  """
  def post_triage_reply(%Scope{} = scope, %Item{id: item_id}, attrs) do
    item = Repo.get!(Item, item_id)

    with :ok <- open(item),
         item = Repo.preload(item, [:created_issue, :existing_issue, thread: [slack_channel: :slack_workspace]]),
         {:ok, drafted} <- item |> Item.draft_changeset(attrs) |> Ecto.Changeset.apply_action(:update),
         :ok <- can_link_issue(item.thread, drafted.reply_text),
         {:ok, text} <- text(drafted),
         :ok <- can_post_to_slack(scope, item.thread),
         :ok <- claim_reply(item, scope.user.id),
         {:ok, message} <- post(scope, item, text) do
      # From here the reply is what went to Slack, placeholder filled, not the draft.
      {:ok, item} =
        item
        |> Ecto.Changeset.change(
          reply_posted_at: DateTime.utc_now(),
          reply_posted_by_id: scope.user.id,
          reply_text: message.text
        )
        |> Repo.update()

      {:ok, _thread} = settle_thread(item.thread)
      {:ok, item}
    end
  end

  defp post(scope, item, text) do
    with {:error, reason} <- post_to_slack(scope, item.thread, text) do
      :ok = release_reply(item)
      {:error, reason}
    end
  end

  defp open(%Item{retriaging: true}), do: {:error, :locked}
  defp open(%Item{reply_posted_at: %DateTime{}}), do: {:error, :already_posted}
  defp open(%Item{}), do: :ok

  # The link is to the issue this item created, or to the one that already tracks it.
  defp text(%Item{reply_text: text} = item) when is_binary(text) do
    issue = item.created_issue || item.existing_issue

    cond do
      not String.contains?(text, "{issue link}") -> {:ok, text}
      is_nil(issue) -> {:error, :needs_issue_link}
      true -> {:ok, String.replace(text, "{issue link}", slack_issue_link(issue))}
    end
  end

  defp text(%Item{}), do: {:error, :no_reply}
end
