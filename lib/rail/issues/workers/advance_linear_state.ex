defmodule Rail.Issues.Workers.AdvanceLinearState do
  @moduledoc """
  Moves a ticket's Linear status forward to where its pipeline stage has reached.

  Only ever forward, judged against Linear's live state: somebody may have moved
  the ticket further by hand, and a send-back to the engineer must not undo In Review.
  """
  use Oban.Worker, queue: :issues, max_attempts: 5

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id, "state" => state}}) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue -> advance(Repo.preload(issue, :project), state)
      nil -> :ok
    end
  end

  # In Progress and In Review share Linear's "started" type, so In Review can
  # only be told apart by its name.
  defp advance(%Issue{project: %Project{} = project} = issue, state) do
    with {:ok, %{"issue" => %{"state" => current, "team" => %{"states" => %{"nodes" => states}}}}} <-
           Linear.issue_workflow(project, issue.external_id) do
      target =
        case state do
          "todo" ->
            states |> Enum.filter(&(&1["type"] == "unstarted")) |> Enum.min_by(& &1["position"], fn -> nil end)

          "in_progress" ->
            states |> Enum.filter(&(&1["type"] == "started")) |> Enum.min_by(& &1["position"], fn -> nil end)

          "in_review" ->
            Enum.find(states, &(&1["type"] == "started" and String.downcase(&1["name"]) == "in review"))
        end

      cond do
        is_nil(target) -> :ok
        calculate_rank(target) <= calculate_rank(current) -> :ok
        true -> update_linear(project, issue, %{"stateId" => target["id"]})
      end
    end
  end

  defp update_linear(%Project{} = project, %Issue{} = issue, input) do
    case Linear.update_issue(project, issue.external_id, input) do
      {:ok, %{"issueUpdate" => %{"success" => true}}} -> :ok
      {:ok, _not_updated} -> {:error, {:linear_mutation_failed, "issueUpdate"}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp calculate_rank(%{"type" => type, "position" => position}) do
    type_rank =
      case type do
        "triage" -> 0
        "backlog" -> 1
        "unstarted" -> 2
        "started" -> 3
        _finished_or_unknown -> 4
      end

    {type_rank, position}
  end
end
