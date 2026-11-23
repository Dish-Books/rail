defmodule Rail.Triage.Actions.SyncTriage do
  @moduledoc """
  Folds what a triage pass wrote into the thread's reply, items, messages and chat.

  An item is matched by the key the agent gave it, so a later pass updates what it said about the
  same thing rather than raising it twice. The result is the whole open list: an open item it leaves
  out is gone unless a person ignored it, and a closed item is never changed.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Triage.Schemas.ChatMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @issue_fields [:issue_title, :issue_description, :issue_priority, :issue_estimate]
  @compared [:kind, :title, :verdict, :followup_text | @issue_fields]

  @doc """
  Records `result` against `thread`, whose preloaded messages are the ones the pass started at
  `started_at` read. Returns `{:ok, thread}`, or `{:error, :sending}` without writing while a Send holds it.
  """
  def sync_triage(%Thread{} = thread, %{} = result, %DateTime{} = started_at) do
    now = DateTime.utc_now()
    issues = existing_issues(thread, result.items)
    items = Enum.uniq_by(result.items, & &1.key)

    Repo.transaction(fn ->
      # The lock Send and the edits take, so what a person settled during the pass is seen here.
      current = Repo.one!(from t in Thread, where: t.id == ^thread.id, lock: "FOR UPDATE")
      if Thread.sending?(current), do: Repo.rollback(:sending)

      existing = Map.new(Repo.all(from i in Item, where: i.thread_id == ^thread.id), &{&1.key, &1})
      new_keys = items |> Enum.map(& &1.key) |> Enum.reject(&Map.has_key?(existing, &1))
      positions = new_keys |> Enum.with_index(next_position(existing)) |> Map.new()
      context = %{thread: thread, existing: existing, positions: positions, issues: issues}

      written = Enum.flat_map(items, &write_item(context, &1))
      written_keys = Enum.map(written, & &1.key)

      {_count, removed} =
        Repo.delete_all(
          from(i in Item,
            where:
              i.thread_id == ^thread.id and is_nil(i.sent_at) and is_nil(i.created_issue_id) and
                is_nil(i.issue_created_by_id) and is_nil(i.followup_posted_at) and not i.ignored and
                i.key not in ^written_keys,
            select: i.position
          )
        )

      stamp_messages(thread, result.messages, now)
      items? = Repo.exists?(from i in Item, where: i.thread_id == ^thread.id)
      reply = calculate_reply(current, thread, result)

      updated =
        current
        |> Ecto.Changeset.change(
          Map.merge(reply, %{
            title: result.title || current.title,
            no_response_reason: if(items?, do: nil, else: no_response_reason(result.messages)),
            chat_read_at: started_at
          })
        )
        |> Repo.update!()

      if result.message do
        Repo.insert!(%ChatMessage{
          thread_id: thread.id,
          author: :agent,
          text: String.slice(result.message, 0, 4000),
          changes: calculate_changes(current, reply, existing, written, removed)
        })
      end

      updated
    end)
  end

  defp write_item(context, attrs) do
    case Map.fetch(context.existing, attrs.key) do
      {:ok, %Item{} = item} ->
        if Item.closed?(item),
          do: [],
          else: [item |> Item.triage_changeset(item_attrs(attrs, context.issues)) |> Repo.update!()]

      :error ->
        [insert(context.thread, attrs, context.issues, Map.fetch!(context.positions, attrs.key))]
    end
  end

  defp next_position(existing),
    do: existing |> Map.values() |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

  # A match Rail has not mirrored yet is brought in from its tracker rather than lost, and one
  # the tracker will not hand over is left unlinked. A Rail-tracked project's are all here already.
  defp existing_issues(%Thread{project: project}, items) do
    for identifier <- items |> Enum.map(& &1.existing_issue) |> Enum.filter(&is_binary/1) |> Enum.uniq(),
        {:ok, %Issue{id: id}} <- [Issues.import_issue(project, identifier)],
        into: %{},
        do: {identifier, id}
  end

  defp insert(thread, attrs, issues, position) do
    %Item{thread_id: thread.id}
    |> Item.triage_changeset(attrs |> item_attrs(issues) |> Map.merge(%{key: attrs.key, position: position}))
    |> Repo.insert!()
  end

  # A ticket that covers the item takes a follow-up and no draft; a new one takes a draft and no follow-up.
  defp item_attrs(attrs, issues) do
    existing_issue_id = Map.get(issues, attrs.existing_issue)

    base =
      attrs
      |> Map.take([:kind, :title, :verdict, :summary, :evidence, :assumptions, :issue_note])
      |> Map.put(:existing_issue_id, existing_issue_id)

    if existing_issue_id,
      do: Map.merge(base, Map.put(Map.new(@issue_fields, &{&1, nil}), :followup_text, attrs.followup_text)),
      else: Map.merge(base, Map.put(Map.take(attrs, @issue_fields), :followup_text, nil))
  end

  # A forwarded thread has no reply, and a null reply never clears one. A posted reply is what Slack has,
  # until a pass drafts one for a newer message.
  defp calculate_reply(%Thread{support_conversation_id: id}, _thread, _result) when is_binary(id), do: %{}
  defp calculate_reply(%Thread{}, _thread, %{reply: nil}), do: %{}

  defp calculate_reply(%Thread{reply_posted_at: %DateTime{} = posted_at}, %Thread{} = thread, result) do
    if Enum.any?(thread.messages, &(Thread.triggering?(thread, &1) and DateTime.after?(&1.posted_at, posted_at))),
      do: %{reply_text: result.reply, reply_posted_at: nil, reply_posted_by_id: nil},
      else: %{}
  end

  defp calculate_reply(%Thread{}, _thread, result), do: %{reply_text: result.reply}

  # The line under the agent's answer, such as "Edited the reply · Added item 4 · Removed item 3".
  defp calculate_changes(%Thread{reply_text: old_reply}, reply, existing, written, removed) do
    edited_reply = if is_binary(old_reply) and Map.get(reply, :reply_text, old_reply) != old_reply, do: "Edited the reply"

    items =
      for item <- written do
        previous = Map.get(existing, item.key)

        cond do
          is_nil(previous) -> "Added item #{item.position}"
          Map.take(item, @compared) != Map.take(previous, @compared) -> "Edited item #{item.position}"
          true -> nil
        end
      end

    case Enum.reject([edited_reply | items] ++ Enum.map(Enum.sort(removed), &"Removed item #{&1}"), &is_nil/1) do
      [] -> nil
      changes -> Enum.join(changes, " · ")
    end
  end

  defp stamp_messages(%Thread{messages: messages}, results, now) do
    by_ts = Map.new(results, &{&1.ts, &1})

    Enum.each(messages, fn %Message{} = message ->
      case Map.fetch(by_ts, message.external_id) do
        {:ok, said} ->
          message
          |> Message.triage_changeset(%{
            item_links: said.item_links,
            no_response_reason: if(said.needs_response, do: nil, else: said.reason || "Needs no response."),
            triaged_at: now
          })
          |> Repo.update!()

        :error ->
          if is_nil(message.triaged_at), do: message |> Message.triage_changeset(%{triaged_at: now}) |> Repo.update!()
      end
    end)
  end

  defp no_response_reason(results) do
    results |> Enum.reject(& &1.needs_response) |> Enum.map(& &1.reason) |> Enum.filter(&is_binary/1) |> List.last()
  end
end
