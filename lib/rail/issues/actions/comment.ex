defmodule Rail.Issues.Actions.Comment do
  @moduledoc false

  import Ecto.Query
  import Rail.Issues.Utils.UpsertLinearComment

  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Comments on `issue` in Linear as the scope's user, or as the workspace when
  there is no user or they never linked Linear, and keeps the comment in Rail.

  `attrs` takes a `:body` and, for a reply, the `:parent_id` of the top-level
  comment on this issue it answers.
  """
  def comment(%Scope{} = scope, %Issue{} = issue, %{body: body} = attrs) do
    with {:ok, parent} <- parent(issue, attrs[:parent_id]),
         project = Repo.get(Project, issue.project_id),
         input = Map.reject(%{"issueId" => issue.external_id, "body" => body, "parentId" => parent}, &is_nil(elem(&1, 1))),
         {:ok, %{"commentCreate" => %{"success" => true, "comment" => node}}} <-
           Linear.create_comment(project, input, as: scope) do
      upsert_linear_comment(node)
    else
      {:ok, _not_created} -> {:error, {:linear_mutation_failed, "commentCreate"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parent(_issue, nil), do: {:ok, nil}

  defp parent(%Issue{id: issue_id}, parent_id) do
    query =
      from c in Comment,
        where: c.id == ^parent_id and c.issue_id == ^issue_id and is_nil(c.parent_id),
        select: c.external_id

    case Repo.one(query) do
      external_id when is_binary(external_id) -> {:ok, external_id}
      nil -> {:error, :parent_not_found}
    end
  end
end
