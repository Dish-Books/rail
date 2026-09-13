defmodule Rail.Issues.Actions.Comment do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Comments on `issue` in Linear as the scope's user, or as the workspace when
  there is no user or they never linked Linear. Returns Linear's comment.
  """
  def comment(%Scope{} = scope, %Issue{} = issue, body) do
    project = Repo.get(Project, issue.project_id)
    input = %{"issueId" => issue.external_id, "body" => body}

    case Linear.create_comment(project, input, as: scope) do
      {:ok, %{"commentCreate" => %{"success" => true, "comment" => comment}}} -> {:ok, comment}
      {:ok, _not_created} -> {:error, {:linear_mutation_failed, "commentCreate"}}
      {:error, reason} -> {:error, reason}
    end
  end
end
