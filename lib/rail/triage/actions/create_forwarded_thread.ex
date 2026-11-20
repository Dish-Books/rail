defmodule Rail.Triage.Actions.CreateForwardedThread do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Support.Schemas.Conversation
  alias Rail.Support.Schemas.IntercomWorkspace
  alias Rail.Support.Schemas.Item, as: SupportItem
  alias Rail.Support.Schemas.Message, as: SupportMessage
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @doc """
  Makes the triage thread a Send forwards, Waiting, with a copy of the conversation's messages and the items as
  drafted. Needs the conversation's workspace and messages preloaded; the caller announces it after commit.
  """
  def create_forwarded_thread(%Scope{user: user}, %Conversation{} = conversation, [%SupportItem{} | _more] = items) do
    Repo.transaction(fn ->
      inbox_url = IntercomWorkspace.inbox_url(conversation.intercom_workspace, conversation.external_id)

      with {:ok, thread} <- conversation |> Thread.forwarded_changeset(user, inbox_url) |> Repo.insert(),
           :ok <- insert_each(Enum.map(conversation.messages, &message_changeset(thread, &1))),
           :ok <- items |> Enum.with_index(1) |> Enum.map(&item_changeset(thread, &1)) |> insert_each() do
        thread
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp insert_each(changesets) do
    Enum.reduce_while(changesets, :ok, fn changeset, :ok ->
      case Repo.insert(changeset) do
        {:ok, _row} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp message_changeset(%Thread{} = thread, %SupportMessage{} = message) do
    Message.changeset(thread, %{
      external_id: "intercom:#{message.external_id}",
      author_name: message.author_name,
      from_bot: message.kind == :bot,
      text: forwarded_text(message),
      posted_at: message.posted_at
    })
  end

  defp item_changeset(%Thread{id: thread_id}, {%SupportItem{} = item, position}) do
    Item.triage_changeset(%Item{thread_id: thread_id}, %{
      key: item.key,
      position: position,
      kind: item.kind,
      title: item.title,
      verdict: item.verdict,
      summary: item.summary,
      evidence: Enum.map(item.evidence, &Map.from_struct/1),
      assumptions: Enum.map(item.assumptions, &Map.from_struct/1),
      issue_title: item.issue_title,
      issue_description: item.issue_description,
      issue_priority: item.issue_priority,
      issue_estimate: item.issue_estimate
    })
  end

  # Triage messages have no kinds, and their images load from Slack, so a note says so and files are named.
  defp forwarded_text(%SupportMessage{kind: kind, text: text, attachments: attachments}) do
    prefix = if kind == :note, do: "Internal note: ", else: ""
    files = Enum.map(attachments, &"Attached: #{&1.name}")
    [prefix <> text | files] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end
end
