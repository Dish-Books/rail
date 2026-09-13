defmodule Rail.Issues.Actions.ArchiveIssue do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  def archive_issue(%Issue{} = issue) do
    project = Repo.get(Project, issue.project_id)

    with {:ok, token} <- workspace_token(project) do
      linear_attrs = build_linear_attrs(project)

      case Linear.update_issue(token, issue.external_id, linear_attrs) do
        {:ok, _result} ->
          issue
          |> Issue.changeset(%{state: :canceled, state_name: "Canceled"})
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
