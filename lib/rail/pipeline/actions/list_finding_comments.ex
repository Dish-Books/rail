defmodule Rail.Pipeline.Actions.ListFindingComments do
  @moduledoc """
  The finding comments a reader sees on a task: their own unsent ones, which nobody else sees, and with `sent: true`
  everyone's sent ones too.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the scope user's unsent comments on `task`'s findings, with their findings, in the order Send numbers them.
  `sent: true` adds everyone's sent ones, with their authors.
  """
  def list_finding_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}, opts \\ []) do
    seen =
      if opts[:sent],
        do: dynamic([c], c.status == :sent or c.user_id == ^user_id),
        else: dynamic([c], c.status == :unsent and c.user_id == ^user_id)

    from(comment in FindingComment,
      where: comment.task_id == ^task_id,
      where: ^seen,
      preload: ^if(opts[:sent], do: [:finding, :user], else: [:finding])
    )
    |> Repo.all()
    |> FindingComment.calculate_order()
  end
end
