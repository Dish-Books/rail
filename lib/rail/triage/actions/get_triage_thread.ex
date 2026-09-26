defmodule Rail.Triage.Actions.GetTriageThread do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Triage.Schemas.Correction
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @doc """
  Loads a thread with everything its page shows: the conversation oldest first,
  its items in order with the issues they link and created, and its corrections.
  """
  def get_triage_thread(_scope, id) when is_binary(id) do
    query =
      from t in Thread,
        where: t.id == ^id,
        preload: [
          :project,
          :dismissed_by,
          slack_channel: :slack_workspace,
          messages: ^from(m in Message, order_by: [asc: m.posted_at], preload: :sent_by_user),
          items:
            ^from(i in Item,
              order_by: [asc: i.position],
              preload: [
                :thread,
                :existing_issue,
                :issue_edited_by,
                :reply_edited_by,
                :issue_created_by,
                :reply_posted_by,
                created_issue: :task
              ]
            ),
          corrections: ^from(c in Correction, order_by: [asc: c.inserted_at], preload: [:user, :item])
        ]

    case Repo.one(query) do
      %Thread{} = thread -> {:ok, thread}
      nil -> {:error, :not_found}
    end
  end
end
