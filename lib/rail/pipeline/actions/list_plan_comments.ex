defmodule Rail.Pipeline.Actions.ListPlanComments do
  @moduledoc """
  The plan comments a reader sees on a task: their own unsent ones, which nobody else sees. A sent comment is only
  the message it went out in.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the scope user's unsent comments on `task`, of every target, in the order Send would number them.
  """
  def list_plan_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}) do
    from(comment in PlanComment,
      where: comment.task_id == ^task_id and comment.user_id == ^user_id and comment.status == :unsent
    )
    |> Repo.all()
    |> PlanComment.calculate_round()
  end
end
