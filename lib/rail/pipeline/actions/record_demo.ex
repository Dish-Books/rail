defmodule Rail.Pipeline.Actions.RecordDemo do
  @moduledoc """
  Records a demo of a task at the demo stage, or records it again.

  Entering the stage leaves the recording to a person, because not every change
  is worth a walkthrough. One already recorded is re-recorded as a fresh take.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @retake "Record the walkthrough again, as a fresh take: rehearse, then call `demo_start`, which discards the last one."

  @doc "Starts the demo run on `task`. Returns `{:ok, run}` with it recording."
  def record_demo(%Scope{}, %Task{} = task) do
    # Read again, because the stage and its runs are what this decides on.
    task = Task |> Repo.get!(task.id) |> Repo.preload(:runs)

    with :ok <- recordable(task) do
      if Task.demo_recorded?(task), do: ask_for_retake(task)
      {:ok, task} = task |> Task.changeset(%{demo_skipped_at: nil}) |> Repo.update()
      Pipeline.enter_stage(task, :demo)
    end
  end

  defp recordable(%Task{stage: stage}) when stage != :demo, do: {:error, {:invalid_stage, stage}}

  defp recordable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  defp ask_for_retake(%Task{} = task) do
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: task.project_id, stage: :demo)
    %Run{} = run = Repo.get_by!(Run, task_id: task.id, role_id: role_id)
    run |> Run.changeset(%{pending_answer: @retake}) |> Repo.update!()
  end
end
