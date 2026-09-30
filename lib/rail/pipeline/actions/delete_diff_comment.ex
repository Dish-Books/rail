defmodule Rail.Pipeline.Actions.DeleteDiffComment do
  @moduledoc """
  Removes an unsent comment from the diff. Only the person who wrote it can.
  """

  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Deletes `comment`, which must be the scope user's own.
  """
  def delete_diff_comment(%Scope{user: %{id: user_id}}, %DiffComment{user_id: user_id} = comment) do
    Repo.delete(comment)
  end
end
