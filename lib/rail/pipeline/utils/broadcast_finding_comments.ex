defmodule Rail.Pipeline.Utils.BroadcastFindingComments do
  @moduledoc false

  @doc """
  Tells one author's tabs on a task that their unsent finding comments moved, since nobody else ever sees an unsent one.
  """
  def broadcast_finding_comments(task_id, user_id) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "finding_comments:#{task_id}:#{user_id}", {:finding_comments_changed, task_id})
  end
end
