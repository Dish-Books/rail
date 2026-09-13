defmodule Rail.Issues.Actions.Comment do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def comment(%Issue{} = issue, comment_body, owner_user \\ nil) do
    project = Repo.get(Project, issue.project_id)

    with {:ok, token, _identity} <- resolve_token(owner_user, project) do
      Linear.create_comment(token, issue.external_id, comment_body)
    end
  end
end
