defmodule Rail.Pipeline.Actions.ApproveFixPlan do
  @moduledoc """
  Approves the plan the Review lead saved for a fix round, the only thing that starts its changes: the run is claimed
  with the plan word for word as its next message, a `StartApprovedFixPlan` job committed with the claim resumes the
  lead, and the plan reads approved once they commit. Only the version the person read, still waiting, is approved.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.ReopenReviewRun
  import Rail.Pipeline.Utils.WriteFixPlan

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.StartApprovedFixPlan
  alias Rail.Repo
  alias Rail.Scope

  @steps "Hand the plan to a new engineer, word for word, as the whole of its brief, and have it carry the plan out as written, reporting any step the code makes wrong rather than doing something else. Have the code reviewer read the uncommitted diff against the plan and an explorer re-check any screen a fix touched before anything is committed, then have the engineer commit. Save each finding ruled Fix with `save_finding`, status fixed, the places its fix covered and those it left with why, the test that failed first and the files it changed. In your last message, say what was done with each comment, by its number, and why. End your turn: Rail sends the commit on."

  @doc """
  Approves version `version` of the fix plan on `run`, the task's Review run, as the scope's user, and queues the
  lead's start. Returns `{:ok, run}` as it now stands, claimed, or `{:error, reason}`: `{:fix_plan_replaced, saved_at}`
  when a later version was saved, `{:fix_plan_not_waiting, state}` when it is not waiting on approval, `:stage_running`
  while the lead works.
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

  # The claim and the job commit together, so a claimed run always has a job to start it, and of two Approves only
  # one claims. The job writes the approval again before it spawns, so a crash before the write below still ends right.
  defp approve(%Scope{user: user}, %Run{} = run, %FixPlan{} = fix_plan) do
    approved = %{fix_plan | approved_by: user.name || user.login, approved_at: DateTime.utc_now()}

    job =
      StartApprovedFixPlan.new(%{
        run_id: run.id,
        version: fix_plan.version,
        approved_by: approved.approved_by,
        approved_at: approved.approved_at,
        before: %{stage_outcome: run.stage_outcome, completed_at: run.completed_at, error: run.error}
      })

    result =
      Repo.transaction(fn ->
        with {1, [reopened]} <- reopen_review_run(run, note(fix_plan)),
             {:ok, %Oban.Job{conflict?: false}} <- Oban.insert(job) do
          reopened
        else
          _claimed_or_queued -> Repo.rollback(:stage_running)
        end
      end)

    case result do
      # Written once committed, so the page reads approved while the job waits its turn in the queue.
      {:ok, reopened} ->
        :ok = write_fix_plan(run.task, approved)
        broadcast_pipeline_changed(run.task)
        {:ok, reopened}

      {:error, :stage_running} ->
        {:error, :stage_running}
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
