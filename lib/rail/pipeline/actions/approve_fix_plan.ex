defmodule Rail.Pipeline.Actions.ApproveFixPlan do
  @moduledoc """
  Approves the plan the Review lead saved for a fix round, which is the only thing that starts its changes: the lead
  resumes on the plan word for word, for an engineer that starts from a clean context. Only the version the person
  read, still waiting against the rulings now, is approved, and the run's claim lets one of two Approves spawn.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.ReopenReviewRun
  import Rail.Pipeline.Utils.SendBack
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Scope

  @steps "Hand the plan to a new engineer, word for word, as the whole of its brief, and have it carry the plan out as written, reporting any step the code makes wrong rather than doing something else. Have the code reviewer read the uncommitted diff against the plan and an explorer re-check any screen a fix touched before anything is committed, then have the engineer commit. Save each finding ruled Fix with `save_finding`, status fixed, the places its fix covered and those it left with why, the test that failed first and the files it changed. In your last message, say what was done with each comment, by its number, and why. End your turn: Rail sends the commit on."

  @doc """
  Approves version `version` of the fix plan on `run`, the task's Review run, as the scope's user. Returns
  `{:ok, run}` as it now stands, or `{:error, reason}`: `{:fix_plan_replaced, saved_at}` when a later version was
  saved, `{:fix_plan_not_waiting, state}` when it is not waiting on approval, `:stage_running` while the lead works.
  """
  def approve_fix_plan(%Scope{} = scope, %Run{} = run, version) when is_integer(version) do
    run = Run |> Repo.get!(run.id) |> Repo.preload([task: [:issue, :project, :runs]], force: true)
    task = run.task

    with true <- Scope.can_access_project?(scope, task.project_id) || {:error, :not_found},
         false <- Task.running?(task) && {:error, :stage_running},
         %FixPlan{} = fix_plan <- Pipeline.read_fix_plan(task) || {:error, :no_fix_plan},
         :ok <- latest(fix_plan, version),
         :waiting <- waiting(FixPlan.state(fix_plan, task, Pipeline.list_findings(task))) do
      approve(scope, run, fix_plan)
    end
  end

  defp latest(%FixPlan{version: version}, version), do: :ok
  defp latest(%FixPlan{saved_at: saved_at}, _read), do: {:error, {:fix_plan_replaced, saved_at}}

  defp waiting(:waiting), do: :waiting
  defp waiting(state), do: {:error, {:fix_plan_not_waiting, state}}

  defp approve(%Scope{user: user}, %Run{} = run, %FixPlan{} = fix_plan) do
    name = user.name || user.login
    approved = %{fix_plan | approved_by: name, approved_at: DateTime.utc_now()}
    {:ok, role} = Roles.get_role(id: run.role_id)

    with {1, [reopened]} <- reopen_review_run(run, note(fix_plan)),
         :ok <- write_fix_plan(run.task, approved),
         send_back(run.task, :review_lead, "#{name} approved the fix plan."),
         {:ok, os_process} <- Pipeline.start_review_run(%{reopened | task: run.task, role: role}) do
      broadcast_pipeline_changed(run.task)
      {:ok, os_process.run}
    else
      {0, []} ->
        {:error, :stage_running}

      # The start settled the run, so only the plan goes back to waiting.
      {:error, {:spawn_failed, _reason, %Run{}}} ->
        write_fix_plan(run.task, fix_plan)
        broadcast_pipeline_changed(run.task)
        {:error, :spawn_failed}

      {:error, :dispatch_disabled} ->
        write_fix_plan(run.task, fix_plan)

        {:ok, _settled} =
          Run
          |> Repo.get!(run.id)
          |> Run.changeset(%{
            status: :finished,
            stage_outcome: run.stage_outcome,
            completed_at: run.completed_at,
            error: run.error
          })
          |> Repo.update()

        {:error, :dispatch_disabled}
    end
  end

  defp note(%FixPlan{round: round, plan: plan}) do
    """
    The human approved the fix plan for fix round #{round}. #{@steps}

    <fix_plan>
    #{plan}
    </fix_plan>
    """
  end
end
