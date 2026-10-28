defmodule Rail.Pipeline.Workers.StartEngineer do
  @moduledoc """
  Starts the engineer on a task whose round's plan was just approved, on a clean conversation: the plan is the
  whole of what it is given. A task whose sequence puts a custom stage after Plan starts that stage's agent instead.
  The job is committed with the approval, so the agent starts even if the page that approved is gone, and is retried
  if the start dies part way.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:task_id], states: :incomplete, period: :infinity]

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}, inserted_at: approved_at}) do
    with %Task{stage: stage} = task when stage in [:engineer, :custom] <- Repo.get(Task, task_id),
         false <- spawned?(task, approved_at) do
      {:ok, _started} = Pipeline.enter_stage(task, Task.current_stage(task), fresh: true)
      :ok
    else
      _gone_moved_on_or_spawned -> :ok
    end
  end

  # An attempt that died before its spawn left a run with no process, which nothing else recovers; one that
  # died after it left a process, and starting again would run the engineer twice. Processes from before this
  # approval are an earlier round's, of a task since sent back to Plan.
  defp spawned?(%Task{} = task, approved_at) do
    case Enum.find(Repo.preload(task, runs: :role).runs, &Task.works_stage?(task, &1.role)) do
      %Run{id: run_id} ->
        [run_id: run_id]
        |> Tools.list_os_processes()
        |> Enum.any?(&(DateTime.compare(&1.inserted_at, approved_at) != :lt))

      nil ->
        false
    end
  end
end
