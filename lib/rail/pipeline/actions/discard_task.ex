defmodule Rail.Pipeline.Actions.DiscardTask do
  @moduledoc """
  Stops a task's runs and removes its worktree, branch and scratch folder, for a
  task whose row is about to be deleted with its issue.
  """

  import Rail.Pipeline.Utils.RemoveTaskFiles

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Stops every running run on `task` the way the Stop button does, then removes
  its files. Nothing is stamped on the row, since it is about to go.
  """
  def discard_task(%Task{} = task) do
    task = Repo.preload(task, :runs, force: true)

    for run <- task.runs, Run.running?(run) do
      {:ok, _stopped, _queued} = Pipeline.stop_run(Scope.for_system(), run)
    end

    remove_task_files(task)
  end
end
