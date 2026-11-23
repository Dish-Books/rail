defmodule Rail.Triage.Actions.SendTriageReply do
  @moduledoc false

  import Ecto.Query
  import Rail.Triage.Utils.SettleThread

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @doc """
  Adds every follow-up and creates every ticket not ignored, then posts the reply in Slack as the person.
  A retry does only what is missing. Returns `{:ok, thread}` or `{:error, reason}`.
  """
  def send_triage_reply(%Scope{} = scope, %Thread{id: id}) do
    with :ok <- can_send(scope, load(id)),
         :ok <- claim(id) do
      # Loaded under the lock, so no edit or pass lands between this and the close.
      thread = load(id)

      result =
        try do
          with :ok <- add_followups(scope, thread),
               :ok <- create_tickets(scope, thread),
               do: post_reply(scope, thread, load(id))
        after
          Repo.update_all(from(t in Thread, where: t.id == ^id), set: [send_started_at: nil])
        end

      Repo.update_all(from(t in Thread, where: t.id == ^id), set: [send_error: send_error(result)])
      {:ok, settled} = settle_thread(thread)
      if result == :ok, do: {:ok, settled}, else: result
    end
  end

  defp load(id) do
    Thread
    |> Repo.get!(id)
    |> Repo.preload([
      :project,
      slack_channel: :slack_workspace,
      items: from(i in Item, order_by: [asc: i.position, asc: i.id], preload: [:created_issue, :existing_issue])
    ])
  end

  defp can_send(%Scope{} = scope, %Thread{} = thread) do
    cond do
      not Scope.can_access_project?(scope, thread.project_id) -> {:error, :not_found}
      thread.status == :triaging -> {:error, :triaging}
      is_nil(Thread.send_label(thread)) -> {:error, :nothing_to_send}
      Thread.reply_draft?(thread) -> can_post_to_slack(scope, thread)
      true -> :ok
    end
  end

  # A second tab finds the lock taken; one a crash left behind frees itself.
  defp claim(id) do
    now = DateTime.utc_now()
    stale = DateTime.shift(now, minute: -Thread.send_stale_after_minutes())
    query = from t in Thread, where: t.id == ^id and (is_nil(t.send_started_at) or t.send_started_at < ^stale)

    case Repo.update_all(query, set: [send_started_at: now]) do
      {1, _claimed} -> :ok
      {0, _taken} -> {:error, :already_sending}
    end
  end

  defp add_followups(%Scope{} = scope, %Thread{} = thread) do
    failed =
      for %Item{existing_issue: %Issue{} = issue} = item <- Thread.to_update(thread),
          not followed_up?(scope, thread, item, issue),
          do: item.position

    if failed == [], do: :ok, else: {:error, {:not_updated, failed}}
  end

  # Claimed before the call and given back if the tracker refuses, so two Sends never add the same comment.
  defp followed_up?(scope, %Thread{} = thread, %Item{id: item_id} = item, %Issue{} = issue) do
    claimed = from(i in Item, where: i.id == ^item_id and is_nil(i.followup_posted_at))

    with {1, _claimed} <- Repo.update_all(claimed, set: [followup_posted_at: DateTime.utc_now()]),
         body = if(thread.permalink, do: "#{item.followup_text}\n\nFrom #{thread.permalink}", else: item.followup_text),
         {:error, _reason} <- Issues.comment(scope, issue, %{body: body}) do
      Repo.update_all(from(i in Item, where: i.id == ^item_id), set: [followup_posted_at: nil])
      false
    else
      {0, _taken} -> true
      {:ok, _comment} -> true
    end
  end

  # An item someone already created counts as created, so a retry creates nothing twice.
  defp create_tickets(%Scope{} = scope, %Thread{} = thread) do
    failed =
      for item <- Thread.to_create(thread),
          not created?(create_item_issue(scope, %{item | thread: thread})),
          do: item.position

    if failed == [], do: :ok, else: {:error, {:not_created, failed}}
  end

  defp created?({:ok, %Issue{}}), do: true
  defp created?({:error, :already_created}), do: true
  defp created?({:error, _reason}), do: false

  # `sent` is the thread as Send loaded it; `now` has the tickets just created.
  defp post_reply(%Scope{} = scope, %Thread{} = sent, %Thread{} = now) do
    item_ids = for item <- sent.items, is_nil(item.sent_at), do: item.id
    items = Enum.filter(now.items, &(&1.id in item_ids))

    if Thread.reply_draft?(now) do
      with :ok <- claim_reply(now, scope.user.id),
           {:ok, message} <- post_claimed(scope, now, calculate_text(now, items)) do
        close_round(scope, now, items, message.text)
      end
    else
      close_round(scope, now, items, nil)
    end
  end

  # The reply is claimed before it goes out, so a Send that outlived its lock never posts it twice.
  defp claim_reply(%Thread{id: id}, user_id) do
    query = from t in Thread, where: t.id == ^id and is_nil(t.reply_posted_by_id) and is_nil(t.reply_posted_at)

    case Repo.update_all(query, set: [reply_posted_by_id: user_id]) do
      {1, _claimed} -> :ok
      {0, _taken} -> {:error, :already_sent}
    end
  end

  defp post_claimed(scope, %Thread{id: id} = thread, text) do
    with {:error, reason} <- post_to_slack(scope, thread, text) do
      Repo.update_all(from(t in Thread, where: t.id == ^id), set: [reply_posted_by_id: nil])
      {:error, {:reply_failed, reason}}
    end
  end

  # The new tickets' links end the reply, except where people outside the team read it.
  defp calculate_text(%Thread{} = thread, items) do
    links = for %Item{created_issue: %Issue{} = issue} <- items, do: slack_issue_link(issue)

    if links == [] or Thread.external?(thread),
      do: thread.reply_text,
      else: "#{thread.reply_text}\n\nFiled as #{Enum.join(links, ", ")}"
  end

  # Under the row lock a pass writes its result under, so a pass ending now sees the reply as posted.
  defp close_round(%Scope{user: user}, %Thread{id: id} = thread, items, posted_text) do
    item_ids = Enum.map(items, & &1.id)

    {:ok, _closed} =
      Repo.transaction(fn ->
        Repo.one!(from t in Thread, where: t.id == ^id, lock: "FOR UPDATE")
        now = DateTime.utc_now()
        Repo.update_all(from(i in Item, where: i.id in ^item_ids), set: [sent_at: now])

        if posted_text,
          do:
            Repo.update_all(from(t in Thread, where: t.id == ^id),
              set: [reply_text: posted_text, reply_posted_at: now, reply_posted_by_id: user.id]
            )
      end)

    # Sending is the person accepting the match, so a ticket that already covers an item points back at the thread.
    for %Item{existing_issue: %Issue{} = issue, ignored: false} <- items,
        is_binary(thread.permalink),
        do: {:ok, _job} = Issues.link_url(issue, thread.permalink, Thread.link_label(thread))

    :ok
  end

  defp send_error(:ok), do: nil

  defp send_error({:error, {:not_updated, positions}}),
    do:
      "Could not add the follow-up on item #{Enum.join(positions, ", ")}, so the reply was not posted. " <>
        "Send again to add it; nothing is done twice."

  defp send_error({:error, {:not_created, positions}}),
    do:
      "Could not create item #{Enum.join(positions, ", ")}, so the reply was not posted. " <>
        "Send again to create it; nothing is done twice."

  defp send_error({:error, {:reply_failed, _reason}}),
    do: "Slack did not take the reply. Send again to post it; nothing else is done twice."

  defp send_error({:error, :already_sent}), do: nil

  # Whether the person can post in the thread as themselves: they linked Slack, in the thread's workspace.
  defp can_post_to_slack(%Scope{} = scope, %Thread{slack_channel: channel}) do
    case Users.slack_token(scope) do
      {:ok, _token, team_id} ->
        if team_id == channel.slack_workspace.external_id, do: :ok, else: {:error, :slack_other_workspace}

      {:error, :not_linked} ->
        {:error, :slack_not_linked}
    end
  end

  # On the person's own Slack token, never the bot's, and recorded as theirs so Slack's echo is not triaged.
  defp post_to_slack(%Scope{} = scope, %Thread{slack_channel: %SlackChannel{} = channel} = thread, text) do
    %SlackChannel{slack_workspace: %{external_id: team_id}} = channel
    {:ok, token, ^team_id} = Users.slack_token(scope)

    with {:ok, %{"ts" => ts}} <- Slack.post_message(token, channel.external_id, thread.external_id, text) do
      {:ok, user} = Users.get_user(id: scope.user.id)
      {:ok, record(thread, user, ts, text)}
    end
  end

  # Slack's echo can land first, so the row may exist already; it becomes theirs either way.
  defp record(thread, %User{} = user, ts, text) do
    thread
    |> Message.changeset(%{
      external_id: ts,
      author_external_id: user.slack_user_id,
      author_name: user.slack_name || user.name || user.login,
      text: String.replace(text, ~r/<[^|>]+\|([^>]+)>/, "\\1"),
      posted_at: DateTime.utc_now()
    })
    |> Ecto.Changeset.put_change(:sent_by_user_id, user.id)
    |> Repo.insert!(
      on_conflict: {:replace, [:sent_by_user_id, :author_external_id, :author_name, :text, :updated_at]},
      conflict_target: [:thread_id, :external_id]
    )
  end

  # Its identifier, linking to its page.
  defp slack_issue_link(%Issue{url: url, identifier: identifier}), do: "<#{url}|#{identifier}>"

  # Two Sends at once create one issue; the ticket links back to where it was reported.
  defp create_item_issue(%Scope{user: %{id: user_id}} = scope, %Item{thread: %Thread{}} = item) do
    with :ok <- claim_issue(item, user_id),
         {:ok, %Issue{} = issue} <- create(scope, item) do
      if item.thread.permalink,
        do: {:ok, _job} = Issues.link_url(issue, item.thread.permalink, Thread.link_label(item.thread))

      {:ok, issue}
    end
  end

  defp claim_issue(%Item{id: item_id}, user_id) do
    case Repo.update_all(from(i in Item, where: i.id == ^item_id and is_nil(i.issue_created_by_id)),
           set: [issue_created_by_id: user_id]
         ) do
      {1, _claimed} -> :ok
      {0, _taken} -> {:error, :already_created}
    end
  end

  defp create(scope, %Item{id: item_id, thread: thread} = item) do
    attrs = %{
      title: item.issue_title,
      description: item.issue_description,
      priority: item.issue_priority,
      estimate: item.issue_estimate
    }

    case Issues.create_issue(scope, thread.project, attrs) do
      {:ok, %Issue{} = issue} ->
        Repo.update_all(from(i in Item, where: i.id == ^item_id), set: [created_issue_id: issue.id])
        {:ok, issue}

      {:error, reason} ->
        Repo.update_all(from(i in Item, where: i.id == ^item_id), set: [issue_created_by_id: nil])
        {:error, reason}
    end
  end
end
