defmodule Rail.Triage.Actions.ListTriageThreads do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @limit 100

  @doc """
  Lists the threads in one status for the queue, `:waiting` unless `:status`
  says otherwise, across every project unless `:project_id` names one or a list. Open
  threads come by their latest message, finished ones by when they finished, at
  most `:limit` of them (100 unless given). Each carries only its first message,
  which is all a row shows.
  """
  def list_triage_threads(opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, :waiting)
    order = if status == :done, do: [desc: :updated_at, desc: :id], else: [desc: :last_message_at, desc: :id]
    first_messages = from(m in Message, distinct: m.thread_id, order_by: [asc: m.thread_id, asc: m.posted_at])

    Thread
    |> where([t], t.status == ^status)
    |> filter_project(opts[:project_id])
    |> order_by(^order)
    |> limit(^Keyword.get(opts, :limit, @limit))
    |> preload([
      :project,
      :dismissed_by,
      :slack_channel,
      messages: ^first_messages,
      items: ^from(i in Item, order_by: [asc: i.position], preload: [:issue_created_by, :reply_posted_by, :created_issue])
    ])
    |> Repo.all()
  end

  defp filter_project(query, nil), do: query
  defp filter_project(query, project_ids) when is_list(project_ids), do: where(query, [t], t.project_id in ^project_ids)
  defp filter_project(query, project_id), do: where(query, [t], t.project_id == ^project_id)
end
