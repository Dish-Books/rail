defmodule Rail.Pipeline.Actions.DeleteDiffComment do
  @moduledoc """
  Removes an unsent comment from the diff. Only the person who wrote it can.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastDiffComments

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Deletes `comment`, which must be the scope user's own and unsent.
  """
  def delete_diff_comment(
        %Scope{user: %{id: user_id}},
        %DiffComment{id: id, user_id: user_id, task_id: task_id, status: :unsent} = comment
      ) do
    # Another of the author's tabs may have removed or sent it already, and a sent
    # one stays.
    Repo.delete_all(from c in DiffComment, where: c.id == ^id and c.user_id == ^user_id and c.status == :unsent)
    broadcast_diff_comments(task_id, user_id)

    {:ok, comment}
  end
end
