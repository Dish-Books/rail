defmodule Rail.Pipeline.Actions.DeleteDiffComment do
  @moduledoc """
  Removes an unsent comment from the diff. Only the person who wrote it can.
  """

  import Rail.Pipeline.Utils.BroadcastDiffComments

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Deletes `comment`, which must be the scope user's own.
  """
  def delete_diff_comment(%Scope{user: %{id: user_id}}, %DiffComment{user_id: user_id, task_id: task_id} = comment) do
    # Another of the author's tabs may have removed or sent it already.
    {:ok, _removed} = deleted = Repo.delete(comment, allow_stale: true)
    broadcast_diff_comments(task_id, user_id)

    deleted
  end
end
