defmodule Rail.Pipeline.Utils.GateOutcome do
  @moduledoc """
  What a gate run's verdict does to the pipeline.

  Review, QA and QA Lead each finish through their own util; this is the logic
  those three share, and `next_stage` is the only thing they differ on once the
  verdict is read.

  A gate only reaches here having stated a verdict, so there is no third case:
  a pass enters `next_stage`, changes requested send the change back to the
  engineer with the findings, until the rework budget runs out and a human has to
  decide instead.
  """

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
  Stamps the gate's fingerprint on `run`, reads its verdict, acts on it, and
  returns the run.
  """
  def gate_outcome(%Run{task: %Task{} = task} = run, next_stage, opts) when is_atom(next_stage) do
    {head_sha, dirty_digest} = resolve_fingerprint(task, run)

    {:ok, run} =
      run
      |> Run.changeset(%{
        stage_fingerprint_head_sha: head_sha,
        stage_fingerprint_dirty_digest: dirty_digest
      })
      |> Repo.update()

    run = %{run | task: task}
    {:ok, task} = record_report(task, run.role_id)

    case Pipeline.parse_stage_verdict(run).verdict do
      :passed -> passed(task, run, next_stage, head_sha, opts)
      :changes_requested -> changes_requested(task, run, opts)
    end
  end

  # Every gate that has looked at the change is listed until the engineer is sent
  # back, so a later gate can carry the earlier ones' findings with it.
  defp record_report(%Task{} = task, gate_role_id) do
    reports = task.outstanding_reports || []

    if gate_role_id in reports do
      {:ok, task}
    else
      task
      |> Task.changeset(%{outstanding_reports: Enum.reverse([gate_role_id | Enum.reverse(reports)])})
      |> Repo.update()
    end
  end

  defp passed(%Task{} = task, %Run{} = run, next_stage, head_sha, opts) do
    if (task.rework_cycles || 0) > 0 and next_stage != :ready_to_merge and head_sha != nil do
      append_evidence_line_to_next_stage(task, next_stage, head_sha)
    end

    Pipeline.enter_stage(task, next_stage, opts)
    run
  end

  defp changes_requested(%Task{} = task, %Run{role_id: gate_role_id} = run, opts) do
    rework_base = task.rework_budget_base || 0
    total_rework = (task.rework_cycles || 0) - rework_base
    cycles_by_gate = task.rework_cycles_by_gate || %{}
    per_gate = Map.get(cycles_by_gate, gate_role_id, 0)

    if total_rework >= @max_rework_cycles or per_gate >= @max_rework_cycles_per_gate do
      exhausted(run, gate_role_id, per_gate)
    else
      send_back_to_engineer(task, run, gate_role_id, cycles_by_gate, per_gate, opts)
    end
  end

  # Out of budget: the task stays where it is with the reason recorded, and a
  # human decides between another round and taking the change as it stands.
  defp exhausted(%Run{task: task} = run, gate_role_id, per_gate) do
    cycle_word = if per_gate == 1, do: "cycle", else: "cycles"

    error =
      "#{resolve_role_name(gate_role_id)} is still requesting changes after #{per_gate} rework #{cycle_word}. " <>
        "Read the findings and decide: Send back to Engineer to have them addressed, " <>
        "or Skip to take the change as it is and go straight to the merge."

    {:ok, run} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{run | task: task}
  end

  defp send_back_to_engineer(%Task{} = task, %Run{} = run, gate_role_id, cycles_by_gate, per_gate, opts) do
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

    {:ok, task} =
      task
      |> Task.changeset(%{
        rework_cycles: new_total_rework,
        rework_cycles_by_gate: Map.put(cycles_by_gate, gate_role_id, per_gate + 1),
        outstanding_reports: []
      })
      |> Repo.update()

    append_pending_answer(task, :engineer, note)
    Pipeline.enter_stage(task, :engineer, opts)
    run
  end

  defp append_evidence_line_to_next_stage(%Task{} = task, next_stage, head_sha) do
    stage_label =
      case task.stage do
        :review -> "the reviewer"
        :qa -> "QA"
        _stage -> "the previous gate"
      end

    note =
      "The change has been reworked and #{stage_label} has signed off on it again. " <>
        "Inspect it as it stands now, re-checking anything you failed it on before.\n\n" <>
        "The reworked change is commit #{head_sha}. Every check you report on this pass must have been run against it: " <>
        "evidence produced before it describes a build that no longer exists, and carrying such a row forward is a false pass. " <>
        "Re-run what you carry, or say plainly that you did not."

    append_pending_answer(task, next_stage, note)
  end

  # The note is waiting on the run before `enter_stage/3` spawns it, so the agent
  # reads it as the first thing in the turn.
  defp append_pending_answer(%Task{} = task, stage, note) do
    with {:ok, %Role{} = role} <- Roles.get_role(project_id: task.project_id, stage: stage),
         %Run{} = run <- Repo.get_by(Run, task_id: task.id, role_id: role.id),
         true <- Run.resumable?(run) do
      Runs.append_pending_answer(run, note)
    else
      _nothing_to_resume -> :ok
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
