defmodule Rail.Pipeline.Actions.CreateDiffComment do
  @moduledoc """
  Saves a comment on one line of a task's diff, unsent, for the person writing it.
  """

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Saves `attrs` as the scope user's comment on `task`.
  """
  def create_diff_comment(%Scope{user: %{id: user_id}}, %Task{id: task_id}, attrs) do
    %DiffComment{task_id: task_id, user_id: user_id}
    |> DiffComment.changeset(attrs)
    |> Repo.insert()
  end
end
