defmodule Rail.Issues.Utils.WriteIssueStatus do
  @moduledoc """
  Writes a status to an issue's row under its lock, so whichever writer finishes the issue is the one that says so.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Repo

  @doc """
  Writes the fields `calculate_attrs` returns for the locked row, tells Learnings and the pipeline when the write
  finishes the issue, and broadcasts `{:issue_changed, issue_id}` on `"issues"`. Returns the row as it now reads.
  """
  def write_issue_status(%Issue{id: id, project_id: project_id}, calculate_attrs) when is_function(calculate_attrs, 1) do
    written =
      Repo.transaction(fn ->
        case Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE")) do
          %Issue{} = locked -> {locked, locked |> Issue.tracker_changeset(calculate_attrs.(locked)) |> Repo.update!()}
          nil -> Repo.rollback(:not_found)
        end
      end)

    with {:ok, {was, issue}} <- written do
      if not Issue.finished_state?(was.state) and Issue.finished_state?(issue.state) do
        {:ok, _job} = Learnings.handle_issue_finished(issue)
        Pipeline.handle_issue_finished(issue)
      end

      Phoenix.PubSub.broadcast(Rail.PubSub, "issues", {:issue_changed, id})
      {:ok, issue}
    end
  end
end
