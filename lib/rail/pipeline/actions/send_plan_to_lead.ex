defmodule Rail.Pipeline.Actions.SendPlanToLead do
  @moduledoc """
  The task's owner sends its plan to the tech leads, which puts it in their queue. Nothing starts: a lead's
  approval does that. Saving the plan again takes it back out, since what was sent is no longer what it says.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.CheckPlan

  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Marks the plan the Plan `run` saved ready for a tech lead, as the scope's user. Returns `{:ok, round}`, or
  `{:error, reason}`: `:not_owner` for anyone but the task's owner, `:stage_running` while Plan works, or what the
  plan is missing.
  """
  def send_plan_to_lead(%Scope{} = scope, %Run{} = run) do
    task = Task |> Repo.get!(run.task_id) |> Repo.preload([:issue, :runs])

    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         :ok <- sendable(scope, task),
         {:ok, %Round{} = round, _design} <- check_plan(task) do
      {:ok, sent} = round |> Round.ready_changeset(scope.user && scope.user.id) |> Repo.update()
      broadcast_pipeline_changed(task)
      {:ok, sent}
    end
  end

  defp sendable(%Scope{}, %Task{stage: stage}) when stage != :plan, do: {:error, {:invalid_stage, stage}}

  defp sendable(%Scope{} = scope, %Task{} = task) do
    cond do
      not (scope.system or Task.owned_by?(task, scope)) -> {:error, :not_owner}
      Task.running?(task) -> {:error, :stage_running}
      true -> :ok
    end
  end
end
