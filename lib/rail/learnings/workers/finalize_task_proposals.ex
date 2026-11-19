defmodule Rail.Learnings.Workers.FinalizeTaskProposals do
  @moduledoc """
  Decides a merged task's proposals as their people chose. The job is committed with the merge, so the rules change
  even when the page or job that merged dies after it.
  """
  use Oban.Worker,
    queue: :learnings,
    max_attempts: 5,
    unique: [keys: [:task_id], states: :incomplete]

  alias Rail.Learnings
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    case Repo.get(Task, task_id) do
      %Task{merged_at: %DateTime{}} = task -> Learnings.finalize_task_proposals(task)
      _gone_or_unmerged -> :ok
    end
  end
end
