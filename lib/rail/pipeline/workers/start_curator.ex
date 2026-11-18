defmodule Rail.Pipeline.Workers.StartCurator do
  @moduledoc """
  Runs a curator pass on a task marked ready for review, outside the click that marked it. While it waits, the
  task's Approve and Merge wait too.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 3,
    unique: [keys: [:task_id], states: :incomplete, period: :infinity]

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    with %Task{} = task <- Repo.get(Task, task_id),
         {:error, :curator_running} <- Pipeline.start_curator(task) do
      {:snooze, 30}
    else
      _started_skipped_or_gone -> :ok
    end
  end
end
