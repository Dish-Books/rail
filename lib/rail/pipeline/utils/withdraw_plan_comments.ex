defmodule Rail.Pipeline.Utils.WithdrawPlanComments do
  @moduledoc false

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPlanComments

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Puts the plan comments queued on `task` back to unsent as `queued`, the message they were in, is handed back
  undelivered, and tells each author's tabs. Returns `queued` without their rounds, which are back in the tray,
  or `nil` when nothing else was queued.
  """
  def withdraw_plan_comments(%Task{id: task_id} = task, queued) when is_binary(queued) do
    {_returned, comments} =
      Repo.update_all(
        from(comment in PlanComment, where: comment.task_id == ^task_id and comment.status == :queued, select: comment),
        set: [status: :unsent, updated_at: DateTime.utc_now()]
      )

    design = Pipeline.read_design(task, pages: false)

    # Each author's round went out as one message written from their comments, so it is written again to find it.
    rest =
      comments
      |> Enum.group_by(& &1.user_id)
      |> Enum.reduce(queued, fn {user_id, round}, text ->
        broadcast_plan_comments(task_id, user_id)
        String.replace(text, PlanComment.calculate_message(PlanComment.calculate_round(round), design), "")
      end)

    case ~r/\n{3,}/ |> Regex.replace(rest, "\n\n") |> String.trim() do
      "" -> nil
      text -> text
    end
  end
end
