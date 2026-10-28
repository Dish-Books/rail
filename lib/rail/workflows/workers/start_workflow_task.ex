defmodule Rail.Workflows.Workers.StartWorkflowTask do
  @moduledoc """
  Starts the task at Plan for an issue a workflow opened. It is committed with the issue, and retried while the
  issue still has no task.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:issue_id], states: :incomplete, period: :infinity]

  import Rail.Workflows.Utils.BroadcastWorkflowsChanged

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}), do: attempt * 120

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"issue_id" => issue_id}}) do
    with {:ok, %Issue{task: nil} = issue} <- Issues.get_issue(issue_id, preload: [:project, :task]),
         false <- Issue.finished_state?(issue.state),
         result = Pipeline.start_task(issue, :plan),
         broadcast_workflows_changed(issue.project),
         {:error, reason} <- result,
         # Retried only while nothing was committed; a spawn refused after the task exists is not.
         {:ok, %Issue{task: nil}} <- Issues.get_issue(issue_id, preload: [:task]) do
      {:error, reason}
    else
      {:error, :not_found} -> :ok
      {:ok, %Issue{task: %Task{}}} -> :ok
      true -> :ok
      {:ok, %Task{}} -> :ok
    end
  end
end
