defmodule Rail.Issues.Actions.Comment do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def comment(scope, %Issue{} = issue, comment_body, owner_user \\ nil) do
    project = Repo.get(Project, issue.project_id)
    user_target = owner_user || scope

    with {:ok, token, _identity} <- resolve_token(user_target, project) do
      Linear.create_comment(token, issue.external_id, comment_body)
    end
  end
end
