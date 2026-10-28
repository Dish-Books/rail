defmodule Rail.Pipeline.Utils.DeliverPlanComments do
  @moduledoc false

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPlanComments

  alias Rail.Learnings
  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  @doc """
  Marks the plan comments queued on `run`'s task sent and learns from them, as the queued message of the Plan `run`,
  or of a custom stage's, goes out with them in it. A run of another role, or one with nothing queued, delivers none.
  """
  def deliver_plan_comments(%Run{pending_chat: queued, role_id: role_id, task_id: task_id}) when is_binary(queued) do
    with {:ok, %Role{stage: stage, custom_stage: custom}} when stage == :plan or is_binary(custom) <-
           Roles.get_role(id: role_id),
         {_claimed, [_first | _rest] = comments} <-
           Repo.update_all(
             from(comment in PlanComment,
               where: comment.task_id == ^task_id and comment.status == :queued,
               select: comment
             ),
             set: [status: :sent, updated_at: DateTime.utc_now()]
           ) do
      # A custom stage's file is its own workflow's, so what a comment on it corrects is no rule for the project.
      learned = Enum.reject(comments, &(&1.target == :output))
      {:ok, _learned} = Learnings.record_corrections(Repo.get!(Task, task_id), learned)
      for user_id <- comments |> Enum.map(& &1.user_id) |> Enum.uniq(), do: broadcast_plan_comments(task_id, user_id)
    end

    :ok
  end

  def deliver_plan_comments(%Run{}), do: :ok
end
