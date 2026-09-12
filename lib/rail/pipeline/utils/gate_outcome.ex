defmodule Rail.Pipeline.Utils.GateOutcome do
  @moduledoc """
  What a gate run's verdict does to the task.

  Review, QA and QA Lead each settle through their own action; this is the logic
  those three share, and the `next_stage` argument is the only thing they differ
  on once the verdict is read.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.CarriedReports
  import Rail.Runs.Utils.AssistantLog

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  @max_rework_cycles 5
  @max_rework_cycles_per_gate 3

  @doc """
  Stamps the gate's fingerprint on `run`, reads its verdict, and returns
  `{task_attrs, run}`.

  A pass moves the task to `next_stage`. Changes requested send the change back
  to the engineer with the findings, until the rework budget runs out and a human
  has to decide. No verdict at all is the same dead end: nothing here guesses one.
  """
  def gate_outcome(%Task{} = task, %Run{} = run, next_stage) when is_atom(next_stage) do
    {head_sha, dirty_digest} = resolve_fingerprint(task, run)

    {:ok, run} =
      run
      |> Run.changeset(%{
        auto_retries: 0,
        stage_fingerprint_head_sha: head_sha,
        stage_fingerprint_dirty_digest: dirty_digest
      })
      |> Repo.update()

    gate_role_id = run.role_id
    reports = task.outstanding_reports || []

    updated_reports =
      if gate_role_id in reports do
        reports
      else
        Enum.reverse([gate_role_id | Enum.reverse(reports)])
      end

    case Pipeline.parse_stage_verdict(run).verdict do
      :passed -> passed(task, run, next_stage, updated_reports, head_sha)
      :changes_requested -> changes_requested(task, run, gate_role_id, updated_reports)
      :unclear -> unclear(run, gate_role_id, updated_reports)
    end
  end

  defp passed(task, run, next_stage, updated_reports, head_sha) do
    next_stage_state = if next_stage == :ready_to_merge, do: :awaiting_approval, else: :queued

    if (task.rework_cycles || 0) > 0 and next_stage != :ready_to_merge and head_sha != nil do
      append_evidence_line_to_next_stage(task, next_stage, head_sha)
    end

    attrs = %{
      stage: next_stage,
      stage_state: next_stage_state,
      outstanding_reports: updated_reports,
      retry_after: nil,
      error: nil
    }

    {attrs, run}
  end

  defp changes_requested(task, run, gate_role_id, updated_reports) do
    rework_base = task.rework_budget_base || 0
    total_rework = (task.rework_cycles || 0) - rework_base
    cycles_by_gate = task.rework_cycles_by_gate || %{}
    per_gate = Map.get(cycles_by_gate, gate_role_id, 0)

    if total_rework >= @max_rework_cycles or per_gate >= @max_rework_cycles_per_gate do
      exhausted(run, gate_role_id, per_gate, updated_reports)
    else
      send_back_to_engineer(task, run, gate_role_id, cycles_by_gate, per_gate)
    end
  end

  defp exhausted(run, gate_role_id, per_gate, updated_reports) do
    cycle_word = if per_gate == 1, do: "cycle", else: "cycles"

    error_msg =
      "#{resolve_role_name(gate_role_id)} is still requesting changes after #{per_gate} rework #{cycle_word}. " <>
        "Read the findings and decide: Send back to Engineer to have them addressed, " <>
        "or Skip to take the change as it is and go straight to the merge."

    attrs = %{
      stage_state: :awaiting_approval,
      outstanding_reports: updated_reports,
      retry_after: nil,
      error: error_msg
    }

    {attrs, run}
  end

  defp send_back_to_engineer(task, run, gate_role_id, cycles_by_gate, per_gate) do
    new_total_rework = (task.rework_cycles || 0) + 1
    findings = String.trim(assistant_log(run))

    note =
      "Findings from #{resolve_role_name(gate_role_id)} on the change you just pushed " <>
        "(rework #{new_total_rework} of #{@max_rework_cycles}). " <>
        "Address every finding, nits included, and the ones marked pre-existing rather than caused by this change too - " <>
        "nobody else picks those up, so leaving one loses it. Work in the same worktree on the same branch, " <>
        "run the project's checks from the top, push to the existing pull request, and say what you changed. " <>
        "Where you disagree with a finding, say why rather than silently leaving it.\n\n" <>
        findings <> carried_reports(task, except: gate_role_id)

    case Roles.get_role(project_id: task.project_id, stage: :engineer) do
      {:ok, eng_role} -> append_pending_answer(task.id, eng_role.id, note, auto_retries: 0)
      _other -> :ok
    end

    attrs = %{
      stage: :engineer,
      stage_state: :queued,
      rework_cycles: new_total_rework,
      rework_cycles_by_gate: Map.put(cycles_by_gate, gate_role_id, per_gate + 1),
      outstanding_reports: [],
      retry_after: nil,
      error: nil
    }

    {attrs, run}
  end

  defp unclear(run, gate_role_id, updated_reports) do
    error_msg =
      "#{resolve_role_name(gate_role_id)} ended without a clear verdict. " <>
        "Read its report, then Send back to Engineer or Skip to the merge."

    attrs = %{
      stage_state: :awaiting_approval,
      outstanding_reports: updated_reports,
      retry_after: nil,
      error: error_msg
    }

    {attrs, run}
  end

  defp append_evidence_line_to_next_stage(task, next_stage, head_sha) do
    case Roles.get_role(project_id: task.project_id, stage: next_stage) do
      {:ok, next_role} ->
        stage_label =
          case task.stage do
            :review -> "the reviewer"
            :qa -> "QA"
            _stage -> "the previous gate"
          end

        evidence_note =
          "The change has been reworked and #{stage_label} has signed off on it again. " <>
            "Inspect it as it stands now, re-checking anything you failed it on before.\n\n" <>
            "The reworked change is commit #{head_sha}. Every check you report on this pass must have been run against it: " <>
            "evidence produced before it describes a build that no longer exists, and carrying such a row forward is a false pass. " <>
            "Re-run what you carry, or say plainly that you did not."

        append_pending_answer(task.id, next_role.id, evidence_note, [])

      _other ->
        :ok
    end
  end

  defp append_pending_answer(task_id, role_id, note, opts) do
    case Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_id) do
      %Run{} = run ->
        if Run.resumable?(run), do: Runs.append_pending_answer(run, note, opts), else: :ok

      nil ->
        :ok
    end
  end

  defp resolve_fingerprint(%Task{worktree_path: path}, run) when is_binary(path) do
    case Git.branch_fingerprint(path) do
      %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
      _other -> {run.stage_fingerprint_head_sha, run.stage_fingerprint_dirty_digest}
    end
  end

  defp resolve_fingerprint(_task, run) do
    {run.stage_fingerprint_head_sha, run.stage_fingerprint_dirty_digest}
  end

  defp resolve_role_name(role_id) do
    case Roles.get_role(id: role_id) do
      {:ok, %Role{name: name}} when is_binary(name) and name != "" -> name
      _other -> to_string(role_id)
    end
  end
end
