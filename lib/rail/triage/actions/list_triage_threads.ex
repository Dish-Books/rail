defmodule Rail.Triage.Actions.ListTriageThreads do
  @moduledoc false

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Triage.Schemas.Item
  alias Rail.Triage.Schemas.Message
  alias Rail.Triage.Schemas.Thread

  @doc """
  Lists the threads in one status for the queue, `:waiting` unless `:status`
  says otherwise, across every project unless `:project_id` names one. Open
  threads come by their latest message, finished ones by when they finished.
  """
  def list_triage_threads(opts \\ []) when is_list(opts) do
    status = Keyword.get(opts, :status, :waiting)
    order = if status == :done, do: [desc: :updated_at, desc: :id], else: [desc: :last_message_at, desc: :id]

    Thread
    |> where([t], t.status == ^status)
    |> then(&if(project_id = opts[:project_id], do: where(&1, [t], t.project_id == ^project_id), else: &1))
    |> order_by(^order)
    |> preload([
      :project,
      :dismissed_by,
      :slack_channel,
      messages: ^from(m in Message, order_by: [asc: m.posted_at]),
      items: ^from(i in Item, order_by: [asc: i.position], preload: [:issue_created_by, :reply_posted_by, :created_issue])
    ])
    |> Repo.all()
  end
end
