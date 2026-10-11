defmodule Rail.Issues.Actions.ImportIssue do
  @moduledoc """
  Brings one ticket into Rail by its identifier, for when something names a
  ticket before the sync or a webhook has mirrored it.

  The row is written with `Issue.tracker_changeset/2`, as a webhook writes it:
  the ticket came from the tracker, so nothing is pushed back.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc """
  The issue `identifier` names on `project`: the one Rail has, or else the
  ticket fetched from the tracker and stored. Returns `{:error, :not_found}` for
  a ticket that is not the project's own, since Rail keeps only those.
  """
  def import_issue(%Project{id: project_id} = project, identifier) when is_binary(identifier) do
    tracker = Tracker.tracker(project)

    case tracker.canonical_identifier(project, identifier) do
      {:ok, canonical} ->
        case Repo.get_by(Issue, project_id: project_id, identifier: canonical) do
          %Issue{} = issue -> {:ok, issue}
          nil -> fetch(tracker, project, canonical)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch(tracker, %Project{} = project, identifier) do
    with {:ok, attrs} <- tracker.fetch_issue(project, identifier),
         {:ok, issue} <-
           (Repo.get_by(Issue, external_id: attrs.external_id) || %Issue{})
           |> Issue.tracker_changeset(Map.merge(attrs, %{project_id: project.id, tracker: project.tracker}))
           |> Repo.insert_or_update() do
      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, issue.id})
      {:ok, issue}
    end
  end
end
