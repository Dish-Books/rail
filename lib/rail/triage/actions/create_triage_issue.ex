defmodule Rail.Triage.Actions.CreateTriageIssue do
  @moduledoc """
  Accepts an item's proposed issue: creates it with the person's edits, starts
  its product stage, and posts its link in the thread as them.
  """

  import Ecto.Query
  import Rail.Triage.Utils.PostToSlack
  import Rail.Triage.Utils.SettleThread
  import Rail.Triage.Utils.SlackIssueLink

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Triage
  alias Rail.Triage.Schemas.Item
  alias Rail.Users

  @doc """
  Nothing is created unless the person can post in the thread. Once Linear has
  the issue it stays, so a later failure is kept on the item rather than undone.
  """
  def create_triage_issue(%Scope{user: %{id: user_id}} = scope, %Item{id: item_id}, attrs) do
    item = Item |> Repo.get!(item_id) |> Repo.preload(thread: [:project, slack_channel: :slack_workspace])

    with :ok <- can_post(scope, item),
         :ok <- open(item),
         {:ok, drafted} <- Triage.update_triage_draft(scope, item, attrs),
         :ok <- claim(item, user_id),
         {:ok, issue} <- create(scope, %{drafted | thread: item.thread}) do
      item = item |> Repo.reload!() |> Repo.preload(thread: [:project, slack_channel: :slack_workspace])
      started = product(issue)
      posted = post(scope, item, issue)
      {:ok, item} = item |> Ecto.Changeset.change(Map.merge(started, posted)) |> Repo.update()
      {:ok, _thread} = settle_thread(item.thread)
      {:ok, item}
    end
  end

  defp can_post(scope, %Item{thread: thread}) do
    case Users.slack_token(scope) do
      {:ok, _token, team_id} ->
        if team_id == thread.slack_channel.slack_workspace.external_id, do: :ok, else: {:error, :slack_other_workspace}

      {:error, :not_linked} ->
        {:error, :slack_not_linked}
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

  defp create(scope, %Item{thread: thread} = item) do
    attrs = %{title: item.issue_title, description: item.issue_description, priority: item.issue_priority}

    case Issues.create_issue(scope, thread.project, attrs) do
      {:ok, %Issue{} = issue} ->
        item |> Ecto.Changeset.change(created_issue_id: issue.id) |> Repo.update!()
        {:ok, issue}

      {:error, reason} ->
        Repo.update_all(from(i in Item, where: i.id == ^item.id), set: [issue_created_by_id: nil])
        {:error, reason}
    end
  end

  defp product(%Issue{} = issue) do
    case Pipeline.start_task(issue, :product) do
      {:ok, _task} -> %{error: nil}
      {:error, reason} -> %{error: "Created #{issue.identifier}, but product did not start: #{inspect(reason)}"}
    end
  end

  defp post(scope, %Item{} = item, %Issue{} = issue) do
    link = slack_issue_link(issue)
    reply? = Item.reply_draft?(item) and is_nil(item.reply_posted_at)

    text =
      cond do
        not reply? -> "Filed as #{link}"
        String.contains?(item.reply_text, "{issue link}") -> String.replace(item.reply_text, "{issue link}", link)
        true -> "#{item.reply_text}\n\nFiled as #{link}"
      end

    case post_to_slack(scope, item.thread, text) do
      {:ok, _message} when reply? -> %{reply_posted_at: DateTime.utc_now(), reply_posted_by_id: scope.user.id}
      {:ok, _message} -> %{}
      {:error, reason} -> %{error: "Created #{issue.identifier}, but could not post in Slack. #{inspect(reason)}"}
    end
  end
end
