defmodule Rail.Issues.Actions.ArchiveIssue do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope

  def archive_issue(scope, %Issue{} = issue) do
    if authorized?(scope) do
      do_archive_issue(scope, issue)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp do_archive_issue(scope, %Issue{} = issue) do
    project = Repo.get(Project, issue.project_id)

    with {:ok, token, _identity} <- resolve_token(scope, project) do
      linear_attrs = build_linear_attrs(project)

      case Linear.update_issue(token, issue.external_id, linear_attrs) do
        {:ok, _result} ->
          issue
          |> Issue.changeset(%{state: :canceled, state_name: "Canceled"}, issue.project_id)
          |> Repo.update()

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_linear_attrs(%Project{linear_state_ids: %{"canceled" => state_id}}) when is_binary(state_id),
    do: %{state_id: state_id}

  defp build_linear_attrs(_other), do: %{}
end
