defmodule Rail.Pipeline.Actions.SkipDemo do
  @moduledoc """
  Settles the demo stage without a recording, for a change that needs none.

  It is the demo done, as far as anything after it is concerned: the stage's run
  is latched done, so the change waits on its merge, and its pull request comes
  out of draft.
  """

  import Rail.Pipeline.Utils.MarkPullRequestReady

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc "Settles `task`'s demo as not needed. Returns `{:ok, run}`, latched done."
  def skip_demo(%Scope{}, %Task{} = task) do
    # Read again, because the stage and its runs are what this decides on.
    task = Task |> Repo.get!(task.id) |> Repo.preload(:runs)

    with :ok <- skippable(task),
         {:ok, %Role{} = role} <- Roles.get_role(project_id: task.project_id, stage: :demo) do
      now = DateTime.utc_now()
      attrs = %{status: :finished, stage_outcome: :done, error: nil, completed_at: now}

      {:ok, run} =
        case Repo.get_by(Run, task_id: task.id, role_id: role.id) do
          %Run{} = run -> run |> Run.changeset(attrs) |> Repo.update()
          nil -> Pipeline.create_run(Map.merge(attrs, %{task_id: task.id, role_id: role.id, started_at: now}))
        end

      Pipeline.append_run_events(run.id, nil, ["[human] No demo is needed for this change."])
      {:ok, task} = task |> Task.changeset(%{demo_skipped_at: now}) |> Repo.update()
      _task = mark_pull_request_ready(task)
      {:ok, run}
    end
  end

  defp skippable(%Task{stage: stage}) when stage != :demo, do: {:error, {:invalid_stage, stage}}

  defp skippable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end
end
