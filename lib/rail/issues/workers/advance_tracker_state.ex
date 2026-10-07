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

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id}}) do
    case Repo.get(Issue, issue_id) do
      %Issue{} = issue -> issue |> Repo.preload([:project, :task]) |> advance()
      nil -> :ok
    end
  end

  # The target comes from where the task is now, not from when the job was queued,
  # so jobs for one issue that run together all aim at the same status.
  defp advance(%Issue{owner_user_id: owner_user_id, task: %Task{stage: stage} = task} = issue)
       when is_binary(owner_user_id) and stage in [:plan, :engineer, :review, :merged] do
    target =
      case stage do
        :merged -> :done
        :review -> :in_review
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
end
