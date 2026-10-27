defmodule Rail.Pipeline.Workers.CleanupMergedTask do
  @moduledoc """
  Cleans up a task once its merge is recorded, waiting for any run in flight to finish first. The job is
  committed with the merge, so the cleanup survives the page or job that merged.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:task_id], states: :incomplete, period: :infinity]

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    # Cleanup never stops a run, and a run stopped on a question is not in flight, so it does not hold this back.
    with %Task{cleaned_up_at: nil} = task <- Repo.get(Task, task_id),
         {:error, :task_busy} <- Pipeline.cleanup_task(task) do
      {:snooze, 30}
    else
      {:ok, %Task{}} -> :ok
      %Task{} -> :ok
      nil -> :ok
    end
  end
end
