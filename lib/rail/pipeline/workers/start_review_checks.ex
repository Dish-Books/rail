defmodule Rail.Pipeline.Workers.StartReviewChecks do
  @moduledoc """
  Starts QA and the code reviewer on a pull request just handed over at Review. The job is committed with the task,
  so the checks start even if the page that handed it over is gone, and is retried if the start dies part way.
  """
  use Oban.Worker,
    queue: :issues,
    max_attempts: 5,
    unique: [keys: [:task_id], states: :incomplete, period: :infinity]

  import Ecto.Query
  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.StartChecks

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}, inserted_at: handed_at}) do
    with %Task{stage: :review, cleaned_up_at: nil} = task <- Repo.get(Task, task_id),
         spawned = spawned(task, handed_at),
         false <- started?(task, spawned) do
      {:ok, task} = Pipeline.enter_stage(task, :review, start: false)
      :ok = start_checks(task, except: spawned)
      broadcast_pipeline_changed(task)
      {:ok, _checked} = Pipeline.check_base(task)
      :ok
    else
      _gone_moved_on_or_started -> :ok
    end
  end

  # An attempt that died after a check spawned its setup or agent left a process, and starting that check again
  # would run it twice; one that died before left a run with no process, which nothing else recovers.
  defp spawned(%Task{} = task, handed_at) do
    stages = Map.new(Repo.preload(task, runs: :role).runs, &{&1.id, &1.role.stage})

    [task_id: task.id]
    |> Tools.list_os_processes()
    |> Enum.filter(&(DateTime.compare(&1.inserted_at, handed_at) != :lt))
    |> Enum.map(&stages[&1.run_id])
    |> Enum.filter(&(&1 in Task.check_stages()))
    |> Enum.uniq()
  end

  # While the worktree's setup is pending, the check carrying it starts the rest once it is done.
  defp started?(%Task{} = task, spawned) do
    %Project{worktree_setup_script: script} = Repo.get!(Project, task.project_id)
    setup_pending? = task.worktree_setup_at == nil and script not in [nil, ""]

    owned =
      Repo.all(
        from(role in Role,
          where: role.project_id == ^task.project_id and role.stage in ^Task.check_stages(),
          select: role.stage
        )
      )

    Enum.all?(owned, &(&1 in spawned)) or (spawned != [] and setup_pending?)
  end
end
