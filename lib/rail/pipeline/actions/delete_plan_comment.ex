defmodule Rail.Pipeline.Actions.DeletePlanComment do
  @moduledoc """
  Removes an unsent plan comment. Only the person who wrote it can, and they can whether or not Plan can be messaged.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPlanComments

  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Deletes `comment`, which must be the scope user's own and unsent.
  """
  def delete_plan_comment(
        %Scope{user: %{id: user_id}},
        %PlanComment{id: id, user_id: user_id, task_id: task_id, status: :unsent} = comment
      ) do
    # Another of the author's tabs may have removed or sent it already, and a sent one stays.
    Repo.delete_all(from c in PlanComment, where: c.id == ^id and c.user_id == ^user_id and c.status == :unsent)
    broadcast_plan_comments(task_id, user_id)

    {:ok, comment}
  end
end
