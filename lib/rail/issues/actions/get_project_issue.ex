defmodule Rail.Issues.Actions.GetProjectIssue do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  The issue `identifier` names on `project`, such as `RAIL-12`, `rail-12` or `12`, or `{:error, :not_found}`.
  """
  def get_project_issue(%Project{id: project_id} = project, identifier) when is_binary(identifier) do
    with {:ok, canonical} <- Tracker.canonical_identifier(project, identifier),
         %Issue{} = issue <- Repo.get_by(Issue, project_id: project_id, identifier: canonical) do
      {:ok, issue}
    else
      _not_found -> {:error, :not_found}
    end
  end
end
