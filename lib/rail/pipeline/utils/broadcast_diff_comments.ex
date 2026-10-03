defmodule Rail.Pipeline.Utils.BroadcastDiffComments do
  @moduledoc false

  @doc """
  Tells every page open on a task that its comments moved: `:everyone`'s when a
  comment is sent or resolved, since all readers see those, or one person's when
  only their unsent comments did.
  """
  def broadcast_diff_comments(task_id, :everyone) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "diff_comments:#{task_id}", {:diff_comments_changed, task_id})
  end

  def broadcast_diff_comments(task_id, user_id) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "diff_comments:#{task_id}:#{user_id}", {:diff_comments_changed, task_id})
  end
end
