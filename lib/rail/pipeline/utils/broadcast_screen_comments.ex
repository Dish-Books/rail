defmodule Rail.Pipeline.Utils.BroadcastScreenComments do
  @moduledoc false

  @doc """
  Tells one author's tabs on a task that their unsent screen comments moved, since nobody else ever sees an unsent one.
  """
  def broadcast_screen_comments(task_id, user_id) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "screen_comments:#{task_id}:#{user_id}", {:screen_comments_changed, task_id})
  end
end
