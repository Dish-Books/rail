defmodule Rail.Pipeline.Actions.UpdatePlanComment do
  @moduledoc """
  Changes the text of an unsent plan comment. Only the person who wrote it can.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPlanComments

  alias Rail.Pipeline.Schemas.PlanComment
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Saves `attrs`' `:body` as the text of `comment`, which must be the scope user's own and unsent.

  Returns `{:ok, comment}`, `{:error, changeset}` for a blank text, or `{:error, :not_found}` once it is gone or sent.
  """
  def update_plan_comment(
        %Scope{user: %{id: user_id}},
        %PlanComment{id: id, user_id: user_id, task_id: task_id, status: :unsent} = comment,
        attrs
      ) do
    now = DateTime.utc_now()

    # Another of the author's tabs may have removed or sent it since, and a sent one keeps the text it was sent with.
    with {:ok, edited} <- comment |> PlanComment.edit_changeset(attrs) |> Ecto.Changeset.apply_action(:update),
         {1, _rows} <-
           Repo.update_all(
             from(c in PlanComment, where: c.id == ^id and c.user_id == ^user_id and c.status == :unsent),
             set: [body: edited.body, updated_at: now]
           ) do
      broadcast_plan_comments(task_id, user_id)
      {:ok, %{edited | updated_at: now}}
    else
      {0, _rows} -> {:error, :not_found}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
