defmodule Rail.Pipeline.Actions.ApprovePlan do
  @moduledoc """
  A tech lead approves a task's initial plan. At Plan that starts the work, as `start_planned_work/4` describes,
  once the task's owner sent the plan or when the lead owns the task, and once the lead's own unsent plan comments are
  sent or removed, since starting deletes them. On a task its owner already started without approval it only records
  the approval, which is what lets the task merge.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.CheckUnsent
  import Rail.Pipeline.Utils.StartPlannedWork

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Approves the plan the Plan `run` saved as the scope's user. Returns `{:ok, run}`, or `{:error, reason}`:
  `:plan_not_ready` while its owner has not sent it, `:already_approved`, `{:unanswered_questions, count}` while
  questions wait on an answer, `{:unsent_comments, count}` while the scope's user has that many plan comments unsent,
  or what the plan is missing.
  """
  def approve_plan(%Scope{} = scope, %Run{} = run) do
    task = Task |> Repo.get!(run.task_id) |> Repo.preload(:issue)

    if task.stage == :plan,
      do: start_planned_work(scope, run, :approved, &allowed(scope, &1, &2)),
      else: approve_started(scope, task, run)
  end

  defp allowed(%Scope{} = scope, %Task{} = task, %Round{} = round) do
    with :ok <- check_unsent(scope, task), do: sent(scope, task, round)
  end

  defp sent(%Scope{system: true}, %Task{}, %Round{}), do: :ok
  defp sent(%Scope{}, %Task{}, %Round{ready_at: %DateTime{}}), do: :ok

  defp sent(%Scope{} = scope, %Task{} = task, %Round{}),
    do: if(Task.owned_by?(task, scope), do: :ok, else: {:error, :plan_not_ready})

  # The initial plan is the first round's, whatever round the work has reached since.
  defp approve_started(%Scope{} = scope, %Task{} = task, %Run{} = run) do
    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         [%Round{approved_at: nil} = round | _later] <- Pipeline.list_rounds(task) do
      {:ok, _approved} = round |> Round.approve_changeset(scope.user && scope.user.id) |> Repo.update()
      broadcast_pipeline_changed(task)
      {:ok, run}
    else
      [%Round{} | _later] -> {:error, :already_approved}
      [] -> {:error, :no_plan}
      {:error, reason} -> {:error, reason}
    end
  end
end
