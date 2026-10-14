defmodule Rail.Pipeline.Actions.RetryRun do
  @moduledoc """
  Retry on an agent run that failed: the engineer at Engineer, or one of the agents checking the round at Review.
  The engineer and the review agent pick their conversation up again where it has one; a check starts over on a
  clean one, since a check is only worth what it read of the round. Nothing else starts until a failed check runs
  again, so this is how a round stalled on one goes on.
  """

  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @retryable %{engineer: [:engineer], review: [:qa, :review, :screens, :demo, :review_lead]}
  @checks [:qa, :review, :screens, :demo]

  @doc """
  Starts `run`'s role again on its task for the scope's user. Returns `{:ok, run}` as it now stands, or
  `{:error, reason}`: `:not_found`, `:stage_running` while anything works on the task, or `:not_retryable` for a
  run that has not failed or belongs to no step the task is at.
  """
  def retry_run(%Scope{} = scope, %Run{} = run) do
    %Run{task: %Task{} = task, role: %Role{} = role} =
      run = Run |> Repo.get!(run.id) |> Repo.preload([:role, :questions, task: :runs])

    cond do
      not Scope.can_access_project?(scope, task.project_id) -> {:error, :not_found}
      Task.running?(task) -> {:error, :stage_running}
      not retryable?(run, task) -> {:error, :not_retryable}
      true -> start_role_run(task, role, fresh: role.stage in @checks or not Run.resumable?(run))
    end
  end

  defp retryable?(%Run{role: %Role{stage: stage}} = run, %Task{stage: task_stage}),
    do: Run.state(run) == :failed and stage in Map.get(@retryable, task_stage, [])
end
