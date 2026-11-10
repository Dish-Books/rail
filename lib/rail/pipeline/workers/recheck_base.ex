defmodule Rail.Pipeline.Workers.RecheckBase do
  @moduledoc """
  Fetches the default branch and checks one task against it, queued when GitHub refuses the task's merge. GitHub
  turns a merge away as soon as the default branch moves under it, while Rail hears of the move only on its next
  fetch, so without this the refusal shows with no Update beside it for up to a quarter of an hour.
  """
  use Oban.Worker, queue: :git, max_attempts: 1, unique: [keys: [:task_id], states: :incomplete, period: :infinity]

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_id" => task_id}}) do
    with %Task{cleaned_up_at: nil} = task <- Repo.get(Task, task_id),
         true <- Task.worktree_present?(task) do
      project = Repo.get!(Project, task.project_id)

      # A fetch that fails still leaves the copy fetched last to check against, which may already show the move.
      with {:error, reason} <- Git.fetch_default_branch(project, task.worktree_path) do
        Logger.warning("Could not fetch #{project.name}'s default branch after a refused merge: #{inspect(reason)}")
      end

      {:ok, _checked} = Pipeline.check_base(task)
    end

    :ok
  end
end
