defmodule Rail.Pipeline.Utils.ReviewRunFinished do
  @moduledoc """
  Where a finished Review lead turn leaves its task.

  The findings are already rows, saved one at a time, and the task stays at Review whatever they say: the
  lead recommends and a person rules, and the fixes they rule happen inside Review. A round that leaves
  nothing to rule and nothing to fix is the exception, and finishes the review by itself, taking the pull
  request out of draft. A message the human queued for the lead holds it, as anyone's unsent finding, diff or
  screen comment does: they have more to say, and Send or Finish review is theirs.

  A turn that leaves commits the remote has not had hands them over: through CI and pushed, and to the next
  round when the branch moved past what the last round read. Fixes are held back while a Fix finding is not
  saved fixed with its report, and a branch Rail will not push goes back to the lead to merge. What else a turn can get wrong is ending without `save_review` when a round
  was due, which at Review is any time the branch has moved since the last pass read it. Both are recorded on the run,
  so the stage stays open for the message that settles them.

  A turn while a fix round's plan waits on approval only plans: it ends with the plan saved, or is recorded as ending
  without one, and whatever it committed past the HEAD the round was sent on is held. The round stays open for the
  person whatever the findings say.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.FinishReview
  import Rail.Pipeline.Utils.SendBackRefusedPush

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DiffComment
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingComment
  alias Rail.Pipeline.Schemas.FixPlan
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.ScreenComment
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc "Finishes `run` as the Review lead's."
  def review_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)
    passes = Pipeline.read_review(task)
    findings = Pipeline.list_findings(task)
    unsent? = Task.worktree_present?(task) and Git.branch_unpushed?(task.worktree_path)
    fix_plan = Pipeline.read_fix_plan(task)

    cond do
      match?(%FixPlan{approved_at: nil}, fix_plan) ->
        planned(run, task, fix_plan, findings, unsent? and head(task) != fix_plan.head)

      unsent? and not saved?(passes, task) and unreported(findings) != [] ->
        fail(run, unreported_error(unreported(findings)))

      unsent? ->
        run |> hand_over() |> after_hand_over(task, passes, findings)

      true ->
        round_finished(run, task, passes, findings)
    end
  end

  # Nothing a planning turn committed is sent on before the plan is approved. Commits from before the Send, such as
  # a fix CI failed, are the approved turn's to send on.
  defp planned(%Run{} = run, %Task{}, %FixPlan{}, _findings, true),
    do:
      fail(
        run,
        "This turn committed while the fix plan waits on approval. Nothing is sent on until the human approves the plan."
      )

  defp planned(%Run{} = run, %Task{} = task, %FixPlan{} = fix_plan, findings, false) do
    if FixPlan.state(fix_plan, task, findings) in [:writing, :revising],
      do: fail(run, "The Review lead did not save a fix plan."),
      else: run
  end

  # A turn that only pushed what the last round already read still owes that round its checks.
  defp after_hand_over(%Run{error: error} = run, _task, _passes, _findings) when is_binary(error), do: run

  defp after_hand_over(%Run{status: status} = run, _task, _passes, _findings)
       when status in [:running, :waiting_for_resources, :waiting_for_usage], do: run

  defp after_hand_over(%Run{} = run, task, passes, findings), do: round_finished(run, task, passes, findings)

  defp hand_over(%Run{} = run) do
    case Pipeline.hand_over_work(Scope.for_system(), run) do
      {:ok, %Run{} = sent} ->
        %{sent | task: run.task, role: run.role}

      {:error, reason} when reason in [:history_rewritten, :pushed_outside_rail] ->
        send_back_refused_push(run, reason)

      {:error, reason} ->
        fail(run, "The Review lead's commits could not be sent on: #{describe(reason)}")
    end
  end

  # Once every finding is ruled, a Fix finding not saved fixed is one the fix round has not reported on.
  defp unreported(findings) do
    if Enum.any?(findings, &Finding.undecided?/1), do: [], else: Enum.filter(findings, &Finding.outstanding?/1)
  end

  defp unreported_error(findings) do
    keys = Enum.map_join(findings, ", ", & &1.key)

    "This turn committed, but #{keys} ruled Fix #{if length(findings) == 1, do: "is", else: "are"} not saved as fixed. " <>
      "Save each with `save_finding`, status fixed, the places its fix covered or left, its test and its files; " <>
      "nothing is sent on until each is."
  end

  defp round_finished(%Run{} = run, %Task{} = task, passes, findings) do
    cond do
      not saved?(passes, task) -> fail(run, "The Review lead did not save its review.")
      run.pending_chat != nil or List.last(passes).finished_at != nil -> run
      Enum.any?(findings, &(Finding.undecided?(&1) or Finding.outstanding?(&1))) -> run
      unsent_comments?(task) -> run
      true -> %{run | task: finish_review(task)}
    end
  end

  defp unsent_comments?(%Task{id: task_id}) do
    Repo.exists?(from c in FindingComment, where: c.task_id == ^task_id and c.status == :unsent) or
      Repo.exists?(from c in DiffComment, where: c.task_id == ^task_id and c.status == :unsent) or
      Repo.exists?(from c in ScreenComment, where: c.task_id == ^task_id and c.status == :unsent)
  end

  # A pass with no commit, or a worktree git cannot read, is taken at its word.
  defp saved?([], %Task{}), do: false

  # Past Review nobody rules a round, so a branch moved at Finalize or after the merge owes none.
  defp saved?(_passes, %Task{stage: stage}) when stage in [:finalize, :merged], do: true

  defp saved?(passes, %Task{} = task) do
    read = List.last(passes).head
    now = head(task)
    is_nil(read) or is_nil(now) or read == now
  end

  defp head(%Task{} = task),
    do: if(Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha])

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp fail(%Run{} = run, error) do
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{failed | task: run.task, role: run.role}
  end
end
