defmodule Rail.Pipeline.Actions.SendPlanComments do
  @moduledoc """
  Sends the plan comments a person has not sent yet to the Plan run as one message, as typing in its chat would,
  and marks them sent. What was sent is learned from.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPlanComments

  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sends the scope user's unsent comments on `run`'s task to the Plan `run`.

  Returns what `Rail.Pipeline.send_message/4` does, or `{:error, :nothing_to_send}` when none are unsent.
  """
  def send_plan_comments(%Scope{user: %{id: user_id}} = scope, %Run{task_id: task_id} = run) do
    mine = from comment in PlanComment, where: comment.task_id == ^task_id and comment.user_id == ^user_id

    # Claimed before sending, so a second tab's Send finds nothing left to send. Committed rather than held in a
    # transaction: the dispatch reads the run from another process, which would not see an uncommitted message.
    {_claimed, comments} =
      Repo.update_all(from(comment in mine, where: comment.status == :unsent, select: comment),
        set: [status: :sent, updated_at: DateTime.utc_now()]
      )

    comments = Enum.sort_by(comments, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
    task = Repo.get!(Task, task_id)

    with [_first | _rest] <- comments,
         message = PlanComment.calculate_message(comments, Pipeline.read_design(task, pages: false)),
         {:ok, _delivery, _run} = sent <- Pipeline.send_message(scope, run, message) do
      {:ok, _learned} = Learnings.record_corrections(task, comments)
      broadcast_plan_comments(task_id, user_id)
      sent
    else
      [] ->
        {:error, :nothing_to_send}

      {:error, reason} ->
        ids = Enum.map(comments, & &1.id)

        Repo.update_all(from(comment in mine, where: comment.id in ^ids and comment.status == :sent),
          set: [status: :unsent, updated_at: DateTime.utc_now()]
        )

        {:error, reason}
    end
  end
end
