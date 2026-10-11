defmodule Rail.Issues.Actions.Comment do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Comments on `issue` in its tracker and keeps the comment in Rail.

  `attrs` takes a `:body` and, for a reply, the `:parent_id` of the top-level
  comment on this issue it answers.
  """
  def comment(%Scope{} = scope, %Issue{} = issue, %{body: body} = attrs) do
    with {:ok, parent} <- parent(issue, attrs[:parent_id]) do
      Tracker.tracker(issue).create_comment(scope, issue, body, parent)
    end
  end

  defp parent(_issue, nil), do: {:ok, nil}

  defp parent(%Issue{id: issue_id}, parent_id) do
    case Repo.one(from c in Comment, where: c.id == ^parent_id and c.issue_id == ^issue_id and is_nil(c.parent_id)) do
      %Comment{} = parent -> {:ok, parent}
      nil -> {:error, :parent_not_found}
    end
  end
end
