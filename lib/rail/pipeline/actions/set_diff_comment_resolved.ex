defmodule Rail.Pipeline.Actions.SetDiffCommentResolved do
  @moduledoc """
  Marks a sent comment resolved, or back to sent, for the person who wrote it.
  Neither tells the engineer anything.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastDiffComments

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Sets whether `comment`, which must be the scope user's own and sent, is resolved.

  Returns `{:error, :not_found}` when it is unsent or gone.
  """
  def set_diff_comment_resolved(
        %Scope{user: %{id: user_id}},
        %DiffComment{id: id, user_id: user_id, task_id: task_id},
        resolved?
      ) do
    status = if resolved?, do: :resolved, else: :sent

    # Matched on what the row holds now, since another tab may have just changed it.
    query =
      from comment in DiffComment,
        where: comment.id == ^id and comment.user_id == ^user_id and comment.status in [:sent, :resolved],
        select: comment

    case Repo.update_all(query, set: [status: status, updated_at: DateTime.utc_now()]) do
      {1, [updated]} ->
        broadcast_diff_comments(task_id, :everyone)
        {:ok, updated}

      {0, []} ->
        {:error, :not_found}
    end
  end
end
