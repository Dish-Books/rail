defmodule Rail.Triage.Actions.CreateTriageIssue do
  @moduledoc """
  Accepts an item's proposed issue: creates it with the person's edits and posts its link
  in the thread as them, unless the channel is external. Its task waits for Start at Plan.
  """

  import Ecto.Query
  import Rail.Triage.Utils.CanLinkIssue
  import Rail.Triage.Utils.CanPostToSlack
  import Rail.Triage.Utils.ClaimReply
  import Rail.Triage.Utils.PostToSlack
  import Rail.Triage.Utils.ReleaseReply
  import Rail.Triage.Utils.SettleThread
  import Rail.Triage.Utils.SlackIssueLink

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage.Schemas.Item

  @doc """
  Nothing is created unless the person can post in the thread. Once the tracker has
  the issue it stays, so a later failure is kept on the item rather than undone.
  """
  def create_triage_issue(%Scope{user: %{id: user_id}} = scope, %Item{id: item_id}, attrs) do
    item = Item |> Repo.get!(item_id) |> Repo.preload(thread: [:project, slack_channel: :slack_workspace])

    with :ok <- can_post_to_slack(scope, item.thread),
         :ok <- open(item),
         {:ok, drafted} <- item |> Item.draft_changeset(attrs) |> Ecto.Changeset.apply_action(:update),
         :ok <- can_link_issue(item.thread, if(is_nil(item.reply_posted_by_id), do: drafted.reply_text)),
         :ok <- claim(item, user_id),
         {:ok, issue} <- create(scope, item, drafted) do
      # The post honors the channel as it was checked, and the row keeps its draft until what was posted replaces it.
      item = %{Repo.reload!(item) | thread: item.thread}
      posted = post(scope, item, drafted, issue)
      {:ok, item} = item |> Ecto.Changeset.change(posted) |> Repo.update()
      {:ok, _thread} = settle_thread(item.thread)
      {:ok, item}
    end
  end

  defp open(%Item{} = item) do
    cond do
      is_binary(item.existing_issue_id) -> {:error, :already_tracked}
      is_binary(item.created_issue_id) -> {:error, :already_created}
      item.retriaging -> {:error, :locked}
      true -> :ok
    end
  end

  # Two people accepting at once create one issue.
  defp claim(%Item{id: item_id}, user_id) do
    case Repo.update_all(from(i in Item, where: i.id == ^item_id and is_nil(i.issue_created_by_id)),
           set: [issue_created_by_id: user_id]
         ) do
      {1, _claimed} -> :ok
      {0, _taken} -> {:error, :already_created}
    end
  end

  # The item keeps the issue as it was created, which is what the person sent.
  defp create(scope, %Item{thread: thread} = item, %Item{} = drafted) do
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
        Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [issue_created_by_id: nil])
        {:error, reason}
    end
  end

  # The reply goes out as the person left it in the form, not as the pass drafted it.
  defp post(scope, %Item{} = item, %Item{reply_text: reply_text} = drafted, %Issue{} = issue) do
    link = slack_issue_link(issue)
    # Someone already posting the reply gets it posted once; the link goes out on its own, never in an external channel.
    reply? = Item.reply_draft?(drafted) and is_nil(item.reply_posted_at) and claim_reply(item, scope.user.id) == :ok

    text =
      cond do
        item.thread.slack_channel.external and reply? -> reply_text
        item.thread.slack_channel.external -> nil
        not reply? -> "Filed as #{link}"
        String.contains?(reply_text, "{issue link}") -> String.replace(reply_text, "{issue link}", link)
        true -> "#{reply_text}\n\nFiled as #{link}"
      end

    case text && post_to_slack(scope, item.thread, text) do
      {:ok, message} when reply? ->
        %{reply_posted_at: DateTime.utc_now(), reply_posted_by_id: scope.user.id, reply_text: message.text}

      {:ok, _message} ->
        %{}

      {:error, reason} ->
        if reply?, do: :ok = release_reply(item)
        %{error: "Created #{issue.identifier}, but could not post in Slack. #{inspect(reason)}"}

      nil ->
        %{}
    end
  end
end
