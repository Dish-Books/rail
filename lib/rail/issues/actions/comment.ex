defmodule Rail.Issues.Actions.Comment do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def comment(scope, %Issue{} = issue, comment_body, owner_user \\ nil) do
    if authorized?(scope) do
      do_comment(scope, issue, comment_body, owner_user)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp do_comment(scope, issue, comment_body, owner_user) do
    project = Repo.get(Project, issue.project_id)
    user_target = owner_user || scope

    with {:ok, token, _identity} <- resolve_token(user_target, project) do
      Linear.create_comment(token, issue.external_id, comment_body)
    end
  end
end
