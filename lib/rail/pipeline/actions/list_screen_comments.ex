defmodule Rail.Pipeline.Actions.ListScreenComments do
  @moduledoc """
  The screen comments a reader sees on a task: their own unsent ones, which nobody else sees. A sent comment is only
  the message it went out in.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the scope user's unsent comments on `task`'s screen states, oldest first, in the order Send numbers them.
  """
  def list_screen_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}) do
    Repo.all(
      from comment in ScreenComment,
        where: comment.task_id == ^task_id and comment.user_id == ^user_id and comment.status == :unsent,
        order_by: [asc: comment.inserted_at, asc: comment.id]
    )
  end
end
