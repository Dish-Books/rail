defmodule Rail.Issues.Actions.HandleLinearWebhook do
  @moduledoc """
  Mirrors an issue event Linear sent for a workspace into Rail.

  The row is written with `Issue.linear_changeset/2`: the change came from
  Linear, so nothing is pushed back to it.
  """

  import Rail.Issues.Utils.FormatLinearIssue

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo

  @doc """
  Applies `payload` for `workspace`. Issue creates and updates are upserted onto
  the workspace's project, removes delete the issue, and anything else is ignored.
  """
  def handle_linear_webhook(%LinearWorkspace{project_id: project_id}, %{
        "type" => "Issue",
        "action" => action,
        "data" => %{"id" => external_id} = data
      })
      when action in ["create", "update"] and is_binary(project_id) do
    attrs = data |> format_linear_issue() |> Map.put(:project_id, project_id)

    (Repo.get_by(Issue, external_id: external_id) || %Issue{})
    |> Issue.linear_changeset(attrs)
    |> Repo.insert_or_update()
  end

  def handle_linear_webhook(%LinearWorkspace{}, %{
        "type" => "Issue",
        "action" => "remove",
        "data" => %{"id" => external_id}
      }) do
    case Repo.get_by(Issue, external_id: external_id) do
      %Issue{} = issue -> Repo.delete(issue)
      nil -> :ok
    end
  end

  def handle_linear_webhook(%LinearWorkspace{}, _payload), do: :ok
end
