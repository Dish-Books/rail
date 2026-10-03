defmodule Rail.Pipeline.Utils.BroadcastDiffComments do
  @moduledoc false

  @doc """
  Tells every page one person has open on a task that their comments moved, so
  each shows them as they are and counts what Send would send.
  """
  def broadcast_diff_comments(task_id, user_id) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "diff_comments:#{task_id}:#{user_id}", {:diff_comments_changed, task_id})
  end
end
