defmodule Rail.Triage.Actions.SyncTriage do
  @moduledoc """
  Folds what a triage pass wrote into the thread's items and messages.

  An item is matched by the key the agent gave it, so a later pass updates what
  it said about the same thing rather than raising it twice. A pass may rewrite
  only the items it was given, and never one a person already settled: those
  are closed, and news about them is a new item. A draft a person already
  accepted is never rewritten.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @doc """
  Records `result` against `thread`, whose preloaded messages are the ones the
  pass read. Only items keyed in `item_keys_in_scope`, or keys the thread has
  never had, are written. Returns `{:ok, thread}`.
  """
  def sync_triage(%Thread{} = thread, %{} = result, item_keys_in_scope) when is_list(item_keys_in_scope) do
    now = DateTime.utc_now()
    existing = Map.new(Repo.all(from i in Item, where: i.thread_id == ^thread.id), &{&1.key, &1})
    issues = existing_issues(thread, result.items)

    items = Enum.uniq_by(result.items, & &1.key)
    new_keys = items |> Enum.map(& &1.key) |> Enum.reject(&Map.has_key?(existing, &1))
    positions = new_keys |> Enum.with_index(next_position(existing)) |> Map.new()

    context = %{
      thread: thread,
      existing: existing,
      positions: positions,
      keys: item_keys_in_scope,
      issues: issues,
      now: now
    }

    Repo.transaction(fn ->
      Enum.each(items, &write_item(context, &1))

      stamp_messages(thread, result.messages, now)

      items? = Repo.exists?(from i in Item, where: i.thread_id == ^thread.id)
      reason = if items?, do: nil, else: no_response_reason(result.messages)

      thread
      |> Ecto.Changeset.change(title: result.title || thread.title, no_response_reason: reason)
      |> Repo.update!()
    end)
  end

  defp write_item(context, attrs) do
    case Map.fetch(context.existing, attrs.key) do
      {:ok, %Item{} = item} ->
        if attrs.key in context.keys and not Item.settled?(item), do: update(item, attrs, context.issues, context.now)

      :error ->
        insert(context.thread, attrs, context.issues, Map.fetch!(context.positions, attrs.key))
    end
  end

  defp next_position(existing),
    do: existing |> Map.values() |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

  defp existing_issues(%Thread{project_id: project_id}, items) do
    identifiers = items |> Enum.map(& &1.existing_issue) |> Enum.filter(&is_binary/1)

    Map.new(
      Repo.all(from i in Issue, where: i.project_id == ^project_id and i.identifier in ^identifiers),
      &{&1.identifier, &1.id}
    )
  end

  defp insert(thread, attrs, issues, position) do
    %Item{thread_id: thread.id}
    |> Item.triage_changeset(attrs |> item_attrs(issues) |> Map.merge(%{key: attrs.key, position: position}))
    |> Repo.insert!()
  end

  defp update(%Item{} = item, attrs, issues, now) do
    attrs = item_attrs(attrs, issues)

    attrs =
      attrs
      |> Map.merge(%{retriaging: false, error: nil, issue_edited_by_id: nil, reply_edited_by_id: nil})
      |> Map.merge(redo(item, attrs, now))
      |> Map.drop(accepted(item))

    item |> Item.triage_changeset(attrs) |> Repo.update!()
  end

  # A redo is a pass a correction asked for; what it overturned stays on the item.
  defp redo(%Item{retriaging: true, verdict: verdict}, %{verdict: new_verdict}, now) do
    if to_string(verdict) == new_verdict, do: %{retriaged_at: now}, else: %{retriaged_at: now, previous_verdict: verdict}
  end

  defp redo(%Item{}, _attrs, _now), do: %{}

  defp accepted(%Item{} = item) do
    issue =
      if item.created_issue_id, do: [:issue_title, :issue_description, :issue_priority, :issue_edited_by_id], else: []

    reply = if item.reply_posted_at, do: [:reply_text, :reply_edited_by_id], else: []
    issue ++ reply
  end

  defp item_attrs(attrs, issues) do
    existing_issue_id = Map.get(issues, attrs.existing_issue)

    base =
      attrs
      |> Map.take([:kind, :title, :verdict, :summary, :evidence, :assumptions, :issue_note, :reply_text])
      |> Map.put(:existing_issue_id, existing_issue_id)

    # An item something already tracks gets no issue drafted for it.
    if existing_issue_id do
      Map.merge(base, %{issue_title: nil, issue_description: nil, issue_priority: nil})
    else
      Map.merge(base, Map.take(attrs, [:issue_title, :issue_description, :issue_priority]))
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
