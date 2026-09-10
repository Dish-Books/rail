defmodule Rail.Issues.Actions.SyncIssues do
  @moduledoc false

  import Ecto.Query
  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Issues.Schemas.Issue
  alias Rail.Repo
  alias Rail.Scope

  def sync_issues(scope, project) do
    if authorized?(scope) do
      do_sync_issues(project)
    else
      {:error, :not_authorized}
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp do_sync_issues(project) do
    with {:ok, token} <- workspace_token(project),
         {:ok, nodes} <- fetch_linear_issues(token, project) do
      upsert_nodes(project.id, nodes)
    end
  end

  defp fetch_linear_issues(token, project) do
    latest_updated =
      Repo.one(
        from i in Issue,
          where: i.project_id == ^project.id,
          select: max(i.linear_updated_at)
      )

    Linear.issues(token, project.linear_team_id, latest_updated)
  end

  defp upsert_nodes(project_id, nodes) do
    Repo.transaction(fn ->
      Enum.map(nodes, fn node ->
        upsert_issue(project_id, node)
      end)
    end)
  end

  defp upsert_issue(project_id, node) do
    attrs = %{
      external_id: node.id,
      identifier: node.identifier,
      title: node.title,
      description: node.description,
      state: map_state_type(node.state && node.state.type),
      state_name: node.state && node.state.name,
      branch_name: node.branch_name,
      url: node.url,
      linear_created_at: parse_datetime(node.created_at),
      linear_updated_at: parse_datetime(node.updated_at)
    }

    case Repo.get_by(Issue, external_id: node.id) do
      %Issue{} = existing ->
        existing
        |> Issue.changeset(attrs, project_id)
        |> Repo.update!()

      nil ->
        %Issue{}
        |> Issue.changeset(attrs, project_id)
        |> Repo.insert!()
    end
  end

  defp map_state_type("triage"), do: :triage
  defp map_state_type("backlog"), do: :backlog
  defp map_state_type("unstarted"), do: :backlog
  defp map_state_type("started"), do: :in_progress
  defp map_state_type("completed"), do: :done
  defp map_state_type("canceled"), do: :canceled
  defp map_state_type(_other), do: :backlog

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _other -> nil
    end
  end
end
