defmodule Rail.Issues.Actions.ImportIssue do
  @moduledoc """
  Brings one Linear ticket into Rail by its identifier, for when something names
  a ticket before the sync or a webhook has mirrored it.

  The row is written with `Issue.linear_changeset/2`, as a webhook writes it:
  the ticket came from Linear, so nothing is pushed back.
  """

  import Ecto.Query
  import Rail.Issues.Utils.FormatLinearIssue

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users.Schemas.User

  @doc """
  The issue `identifier` names on `project`: the one Rail has, or else the
  ticket fetched from Linear and stored. Returns `{:error, :not_found}` for a
  ticket on another team, since Rail keeps only the project's own.
  """
  def import_issue(%Project{id: project_id} = project, identifier) when is_binary(identifier) do
    case Repo.get_by(Issue, project_id: project_id, identifier: identifier) do
      %Issue{} = issue -> {:ok, issue}
      nil -> fetch(project, identifier)
    end
  end

  defp fetch(%Project{linear_team_id: team_id} = project, identifier) do
    case Linear.issue(project, identifier) do
      {:ok, %{"issue" => %{"team" => %{"id" => ^team_id}} = node}} when is_binary(team_id) ->
        attrs =
          node
          |> format_linear_issue()
          |> Map.merge(%{project_id: project.id, owner_user_id: owner_user_id(get_in(node, ["assignee", "id"]))})

        with {:ok, issue} <-
               (Repo.get_by(Issue, external_id: node["id"]) || %Issue{})
               |> Issue.linear_changeset(attrs)
               |> Repo.insert_or_update() do
          Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
          {:ok, issue}
        end

      {:ok, _elsewhere} ->
        {:error, :not_found}

      {:error, {:linear_graphql_error, _errors}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An assignee with no linked Rail user leaves the issue unowned, as the full sync does.
  defp owner_user_id(linear_user_id) when is_binary(linear_user_id) do
    Repo.one(from(u in User, where: u.linear_user_id == ^linear_user_id, select: u.id))
  end

  defp owner_user_id(nil), do: nil
end
