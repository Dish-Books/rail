defmodule Rail.Pipeline.Actions.PurgeTask do
  @moduledoc """
  Stops a task's runs, closes its browsers and removes its worktree, branch and scratch folder, for a task whose
  row is about to be deleted, by Discard or with its issue.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.RemoveTaskFiles

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools

  @doc """
  Stops every running run on `task` the way the Stop button does, closes its browser sessions, removes its files,
  then deletes its runs. Nothing is stamped on the task row, and the caller announces the change once the row goes.
  """
  def purge_task(%Task{id: task_id} = task) do
    task = Repo.preload(task, :runs, force: true)

    for run <- task.runs, Run.running?(run) do
      {:ok, _stopped, _queued} = Pipeline.stop_run(Scope.for_system(), run)
    end

    # The task's delete takes the session rows with it, and nothing closes a Chrome context without its row.
    :ok = Tools.stop_browser_session(task)
    remove_task_files(task)

    # Runs have no foreign key to tasks; a run's processes, events and questions cascade from it.
    Repo.delete_all(from(r in Run, where: r.task_id == ^task_id))

    :ok
  end
end
