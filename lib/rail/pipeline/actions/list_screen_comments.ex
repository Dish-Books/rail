defmodule Rail.Pipeline.Actions.ListScreenComments do
  @moduledoc """
  The screen comments a reader sees on a task: their own unsent ones, which nobody else sees, and with `sent: true`
  everyone's sent ones too.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the scope user's unsent comments on `task`'s screen states, oldest first, in the order Send numbers them.
  `sent: true` adds everyone's sent ones, with their authors.
  """
  def list_screen_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}, opts \\ []) do
    seen =
      if opts[:sent],
        do: dynamic([c], c.status == :sent or c.user_id == ^user_id),
        else: dynamic([c], c.status == :unsent and c.user_id == ^user_id)

    Repo.all(
      from comment in ScreenComment,
        where: comment.task_id == ^task_id,
        where: ^seen,
        order_by: [asc: comment.inserted_at, asc: comment.id],
        preload: ^if(opts[:sent], do: [:user], else: [])
    )
  end
end
