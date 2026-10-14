defmodule Rail.Pipeline.Actions.RecordDemo do
  @moduledoc """
  Re-record on a demo the branch has moved past: starts the demo recorder on HEAD, a run of its own. Refused
  while anything works on the task, since the recorder needs the worktree's app server to itself, so two clicks
  record once.
  """

  import Rail.Pipeline.Utils.StartRoleRun

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @doc """
  Starts the demo recorder on `task` for the scope's user. Returns `{:ok, run}` as it now stands, or
  `{:error, reason}` for a project the scope cannot open, a task not at Review, one something works on, or a
  project with no demo role.
  """
  def record_demo(%Scope{} = scope, %Task{} = task) do
    task = Task |> Repo.get!(task.id) |> Repo.preload(:runs)

    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         :ok <- recordable(task),
         {:ok, role} <- Roles.get_role(project_id: task.project_id, stage: :demo) do
      start_role_run(task, role, fresh: true)
    else
      {:error, :role_not_found} -> {:error, :not_found}
      {:error, _reason} = refused -> refused
    end
  end

  defp recordable(%Task{stage: stage}) when stage != :review, do: {:error, {:invalid_stage, stage}}
  defp recordable(%Task{} = task), do: if(Task.running?(task), do: {:error, :stage_running}, else: :ok)
end
