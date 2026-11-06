defmodule Rail.Pipeline.Workers.StartEngineer do
  @moduledoc """
  Starts the engineer on a task whose round's plan was just approved, on a clean conversation: the plan is the
  whole of what it is given. A task whose sequence puts a custom stage after Plan starts that stage's agent instead,
  and an approved custom stage's job, naming the stage it moved the task to, starts Plan or Review too. The job is
  committed with the approval, so the stage starts even if the page that approved is gone, and is retried if the
  start dies part way. A task discarded or sent back to Plan while the job waited starts nothing.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:task_id], states: :incomplete, period: :infinity]

  import Rail.Pipeline.Utils.StartChecks
  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id} = args, inserted_at: approved_at}) do
    # Read under the task's lock, so a task discarded or sent back to Plan while the job waited starts nothing.
    with_task_lock(task_id, fn ->
      with %Task{stage: stage, cleaned_up_at: nil} = task <- Repo.get(Task, task_id),
           true <- stage in [:engineer, :custom] or stage in moved_to(args),
           false <- spawned?(task, approved_at) do
        :ok = start(task)
      else
        _gone_moved_on_or_spawned -> :ok
      end
    end)
  end

  # Only an approved custom stage's job moves a task on to Plan or Review.
  defp moved_to(%{"stage" => "plan"}), do: [:plan]
  defp moved_to(%{"stage" => "review"}), do: [:review]
  defp moved_to(_args), do: []

  # A round that brought the branch up to date clears its Update, and one that did not may still need it.
  defp start(%Task{stage: :review} = task) do
    {:ok, reviewing} = Pipeline.check_base(task)
    start_checks(reviewing)
  end

  defp start(%Task{} = task) do
    {:ok, _started} = Pipeline.enter_stage(task, Task.current_stage(task), fresh: true)
    :ok
  end

  # An attempt that died before its spawn left a run with no process, which nothing else recovers; one that
  # died after it left a process, and starting again would run the stage twice. Processes from before this
  # approval are an earlier round's, of a task since sent back to Plan.
  defp spawned?(%Task{} = task, approved_at) do
    run_ids = for run <- Repo.preload(task, runs: :role).runs, started_run?(task, run), do: run.id

    Enum.any?(run_ids, fn run_id ->
      [run_id: run_id]
      |> Tools.list_os_processes()
      |> Enum.any?(&(DateTime.compare(&1.inserted_at, approved_at) != :lt))
    end)
  end

  # Review's start spawns the checks, not the lead.
  defp started_run?(%Task{stage: :review}, %Run{role: %Role{stage: stage}}), do: stage in Task.check_stages()
  defp started_run?(%Task{} = task, %Run{role: role}), do: Task.works_stage?(task, role)
end
