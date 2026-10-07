defmodule Rail.Pipeline.Utils.BroadcastPlanComments do
  @moduledoc false

  @doc """
  Tells one author's tabs on a task that their unsent plan comments moved, the only thing any page shows of them.
  """
  def broadcast_plan_comments(task_id, user_id) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "plan_comments:#{task_id}:#{user_id}", {:plan_comments_changed, task_id})
  end
end
