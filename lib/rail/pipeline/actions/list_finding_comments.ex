defmodule Rail.Pipeline.Actions.ListFindingComments do
  @moduledoc """
  The finding comments a reader sees on a task: their own unsent ones, which nobody else sees. A sent comment is only
  the message it went out in.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Returns the scope user's unsent comments on `task`'s findings, with their findings, in the order Send numbers them.
  """
  def list_finding_comments(%Scope{user: %{id: user_id}}, %Task{id: task_id}) do
    from(comment in FindingComment,
      where: comment.task_id == ^task_id and comment.user_id == ^user_id and comment.status == :unsent,
      preload: [:finding]
    )
    |> Repo.all()
    |> FindingComment.calculate_order()
  end
end
