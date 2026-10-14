defmodule Rail.Pipeline.Actions.EnterStage do
  @moduledoc """
  Moves a task to a stage and starts that stage's run.

  This is the only thing that writes `task.stage`, and the only thing that puts a
  run back to `:in_progress`. Both halves belong together: entering a stage is
  exactly the moment that stage gets to conclude something again, so a reviewer
  that already passed can pass afresh on the rework, and an engineer that already
  said it was done can say it about the next round.

  Nothing settles its way here. A run that finishes decides what its own stage
  concluded and then calls this if that conclusion means moving; the move is
  never a side effect of a process exiting.

  Entering a stage also moves the task's ticket forward in its tracker to match it.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Issues
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role

  # The stages a ticket's tracker status follows; the rest leave it where it is.
  # Only a split parent enters `:merged`, once its last child has, and its ticket is then Done.
  @tracked_stages [:plan, :engineer, :review, :merged]

  @doc """
  Enters `stage` on `task` and spawns the role that works it, `Task.role_stage/1`'s.

  Returns `{:ok, run}` with the run left executing, or `{:ok, task}` under
  `start: false`, which records the move and stops there, for a stage a person
  decides whether to run at all. `fresh: true` starts the role on a new conversation, as a round does.
  """
  def enter_stage(%Task{} = task, stage, opts \\ []) when is_atom(stage) do
    {:ok, task} = claim_stage(task, stage)

    result =
      if Keyword.get(opts, :start, true) do
        {:ok, %Role{} = role} = Roles.get_role(project_id: task.project_id, stage: Task.role_stage(stage))
        start_role_run(task, role, Keyword.take(opts, [:fresh]))
      else
        {:ok, task}
      end

    # Outside claim_stage's transaction, so whoever reloads on it reads the new stage.
    broadcast_pipeline_changed(task)
    result
  end

  # The stage and the job that moves its ticket land together or not at all.
  defp claim_stage(%Task{} = task, stage) do
    Repo.transaction(fn ->
      task = task |> Task.changeset(%{stage: stage}) |> Repo.update!()

      if stage in @tracked_stages do
        {:ok, _job} = Issues.advance_issue_state(Repo.preload(task, :issue).issue)
      end

      task
    end)
  end
end
