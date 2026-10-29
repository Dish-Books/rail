defmodule Rail.Pipeline.Actions.RetryRun do
  @moduledoc """
  Retry on an agent run that failed: the engineer at Engineer, a custom stage's agent at its stage, or one of the
  agents checking the round at Review.
  The engineer and the review agent pick their conversation up again where it has one; a check starts over on a
  clean one, since a check is only worth what it read of the round. Nothing else starts until a failed check runs
  again, so this is how a round stalled on one goes on. QA skipped on a round that changed nothing a person sees is
  started the same way, by a person who wants it walked anyway.
  """

  import Rail.Pipeline.Utils.StartRoleRun
  import Rail.Pipeline.Utils.WithTaskLock

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @retryable %{engineer: [:engineer], review: [:qa, :review, :demo, :review_lead]}
  @checks [:qa, :review, :demo]

  @doc """
  Starts `run`'s role again on its task for the scope's user. Returns `{:ok, run}` as it now stands, or
  `{:error, reason}`: `:not_found`, `:stage_running` while anything works on the task, or `:not_retryable` for a
  run that is gone, has neither failed nor been skipped, or belongs to no step the task is at.
  """
  def retry_run(%Scope{} = scope, %Run{id: run_id, task_id: task_id}) do
    # Under the task's lock, so a run Discard or Back to Plan deletes cannot be started again around it.
    with_task_lock(task_id, fn ->
      case Run |> Repo.get(run_id) |> Repo.preload([:role, :questions, task: :runs]) do
        %Run{} = run -> retry(scope, run)
        nil -> {:error, :not_retryable}
      end
    end)
  end

  defp retry(scope, %Run{task: %Task{} = task, role: %Role{} = role} = run) do
    cond do
      not Scope.can_access_project?(scope, task.project_id) -> {:error, :not_found}
      Task.running?(task) -> {:error, :stage_running}
      not retryable?(run, task) -> {:error, :not_retryable}
      true -> start_role_run(task, role, fresh: role.stage in @checks or not Run.resumable?(run))
    end
  end

  defp retryable?(%Run{role: %Role{stage: stage} = role} = run, %Task{stage: task_stage} = task) do
    (Run.state(run) == :failed or run.stage_outcome == :skipped) and
      (stage in Map.get(@retryable, task_stage, []) or (task_stage == :custom and Task.works_stage?(task, role)))
  end
end
