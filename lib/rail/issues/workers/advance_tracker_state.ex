defmodule Rail.Issues.Workers.AdvanceTrackerState do
  @moduledoc """
  Moves a ticket's status forward in its tracker to where its task's stage has reached.

  Only ever forward, judged against the tracker's live state: somebody may have moved
  the ticket further by hand, and a send-back to the engineer must not undo In Review.

  Only once the issue has an owner: an unowned ticket stays where it is, and the write
  that gives it one, `Rail.Issues.Schemas.Issue`'s changeset or the full sync, queues
  this job to catch it up with its task.

  One job per issue at a time, so two can never race their writes. That job covers
  any later stage: it reads the stage when it runs, and runs again if it moved meanwhile.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:issue_id], states: :incomplete, period: :infinity]

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id}}) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue -> advance(%{Repo.preload(issue, :project) | task: task(issue)})
      nil -> :ok
    end
  end

  # The target comes from where the task is now, not from when the job was queued,
  # so jobs for one issue that run together all aim at the same status.
  defp advance(%Issue{owner_user_id: owner_user_id, task: %Task{stage: stage} = task} = issue)
       when is_binary(owner_user_id) and stage in [:plan, :engineer, :review, :finalize, :merged] do
    target =
      case stage do
        :merged -> :done
        # Finalize is still the pull request in review, waiting on a tech lead to merge it.
        stage when stage in [:review, :finalize] -> :in_review
        _plan_or_engineer -> :in_progress
      end

    result = Tracker.tracker(issue).advance_issue(issue, target)

    # A stage entered while this ran was refused a job of its own, so run again for it.
    # An error needs no check: Oban's retry reads the stage afresh anyway.
    cond do
      result != :ok -> result
      match?(%Task{stage: ^stage}, Repo.reload(task)) -> :ok
      true -> {:snooze, 1}
    end
  end

  defp advance(%Issue{}), do: :ok

  # The issue's newest task whatever its cleanup, since a merged one may be cleaned up before this runs.
  # When that newest task was cleaned up short of Merged, there is none, so an older merge moves nothing.
  defp task(%Issue{id: issue_id}) do
    case Repo.one(from(t in Task, where: t.issue_id == ^issue_id, order_by: [desc: t.inserted_at, desc: t.id], limit: 1)) do
      %Task{cleaned_up_at: nil} = task -> task
      %Task{stage: :merged} = task -> task
      %Task{} -> nil
      nil -> nil
    end
  end
end
