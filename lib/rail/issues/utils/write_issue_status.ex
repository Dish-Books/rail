defmodule Rail.Issues.Utils.WriteIssueStatus do
  @moduledoc """
  Writes a status to an issue's row under its lock, so whichever writer finishes the issue is the one that says so.
  """

  import Ecto.Query

  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Learnings
  alias Rail.Pipeline
  alias Rail.Repo

  @doc """
  Writes the fields `calculate_attrs` returns for the locked row, tells Learnings and the pipeline when the write
  finishes the issue, and broadcasts `{:issue_changed, issue_id}` on `"issues"`. A Rail-tracked issue that starts joins
  the cycle running today in the same write. Returns the row as it now reads.
  """
  def write_issue_status(%Issue{id: id, project_id: project_id}, calculate_attrs) when is_function(calculate_attrs, 1) do
    written =
      Repo.transaction(fn ->
        case Repo.one(from(i in Issue, where: i.id == ^id and i.project_id == ^project_id, lock: "FOR UPDATE")) do
          %Issue{} = locked ->
            attrs = locked |> calculate_attrs.() |> join_running_cycle(locked)
            {locked, locked |> Issue.tracker_changeset(attrs) |> Repo.update!()}

          nil ->
            Repo.rollback(:not_found)
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

  # Judged on the locked row, so the daily job's close waits for it and reads where the issue went.
  defp join_running_cycle(attrs, %Issue{tracker: :local} = locked) do
    if Issue.started_state?(attrs[:state]) and not Issue.started_state?(locked.state) do
      today = Date.utc_today()

      running =
        Repo.one(
          from(c in Cycle,
            where: c.project_id == ^locked.project_id and c.starts_on <= ^today and c.ends_on >= ^today,
            select: c.id
          )
        )

      if running in [nil, locked.cycle_external_id], do: attrs, else: Map.put(attrs, :cycle_external_id, running)
    else
      attrs
    end
  end

  defp join_running_cycle(attrs, %Issue{}), do: attrs
end
