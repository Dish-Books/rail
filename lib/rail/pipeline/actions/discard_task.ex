defmodule Rail.Pipeline.Actions.DiscardTask do
  @moduledoc """
  Stops a task's runs and removes its worktree, branch and scratch folder, for a
  task whose row is about to be deleted with its issue.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.RemoveTaskFiles

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Stops every running run on `task` the way the Stop button does, removes its
  files, then deletes its runs, designs and demos. Nothing is stamped on the task row,
  and the caller announces the change once the task's issue is deleted too.
  """
  def discard_task(%Task{id: task_id} = task) do
    task = Repo.preload(task, :runs, force: true)

    for run <- task.runs, Run.running?(run) do
      {:ok, _stopped, _queued} = Pipeline.stop_run(Scope.for_system(), run)
    end

    remove_task_files(task)

    # None of these has a foreign key to tasks; a run's processes, events and questions cascade from it.
    {:ok, _deleted} =
      Repo.transaction(fn ->
        Repo.delete_all(from(r in Run, where: r.task_id == ^task_id))
        Repo.delete_all(from(d in "designs", where: d.task_id == ^task_id))
        Repo.delete_all(from(d in "demos", where: d.task_id == ^task_id))
      end)

    :ok
  end
end
