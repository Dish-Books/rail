defmodule Rail.Pipeline.Actions.SettleRun do
  @moduledoc """
  Settles finished agent runs, captures stage scratch artifacts, advances the pipeline,
  and classifies transient vs permanent failures with automatic retry backoff.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.CarriedReports, only: [build_carried_gate_reports: 2]
  import Rail.Pipeline.Utils.Scratch

  alias Rail.Domain.RunFailure
  alias Rail.Domain.StageVerdict
  alias Rail.Domain.TaskUsage
  alias Rail.Git
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run

  @doc """
  Settles a finished run for a task:
  - Updates `RoleRun` and `Run` records with exit codes, outputs, and usage.
  - Captures scratch artifacts via `Scratch.capture/3`.
  - Advances stage or sets approval gates on exit 0.
  - Applies retry backoff or marks failure on non-zero exit.
  - Broadcasts `pipeline_changed`.
  """
  def settle_run(task_target, role_run_target, run_or_outcome \\ %{}, opts \\ []) do
    with %Task{} = task <- resolve_task(task_target),
         %RoleRun{} = role_run <- resolve_role_run(role_run_target) do
      if chat_run?(run_or_outcome) do
        Rail.Pipeline.settle_chat_turn(task, role_run, run_or_outcome, opts)
      else
        do_settle_run(task, role_run, run_or_outcome, opts)
      end
    else
      _not_found -> {:error, :not_found}
    end
  end

  defp chat_run?(%Run{kind: :chat}), do: true
  defp chat_run?(%{run: %Run{kind: :chat}}), do: true
  defp chat_run?(%{kind: :chat}), do: true
  defp chat_run?(_other), do: false

  defp do_settle_run(%Task{} = task, %RoleRun{} = role_run, run_or_outcome, opts) do
    exit_code = resolve_exit_code(run_or_outcome, role_run)
    error = resolve_error(run_or_outcome, role_run)
    output = resolve_output(run_or_outcome, role_run)
    usage = resolve_usage(run_or_outcome, role_run)

    maybe_finish_run(run_or_outcome)

    {:ok, role_run} = update_role_run(role_run, exit_code, error, output, usage)
    {task, role_run} = maybe_detect_and_register_question(task, role_run, run_or_outcome, output)

    scratch_dir =
      Keyword.get(opts, :scratch_dir) ||
        Keyword.get(opts, :scratch_path) ||
        default_scratch_path(task.project_id, task.id)

    {:ok, task} = capture(task.stage, task, scratch_dir)
    {task_attrs, updated_role_run} = resolve_settle_outcome(task, role_run, exit_code, error)

    {:ok, updated_task} =
      task
      |> Task.changeset(task_attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :run_settled})
    Rail.Pipeline.maybe_dispatch_queued_pending_chat(updated_task, opts)
    final_task = maybe_refresh_rebase_mergeability(updated_task, task, exit_code, opts)

    {:ok, final_task, updated_role_run}
  end

  defp maybe_detect_and_register_question(task, role_run, run_or_outcome, output) do
    detected_question =
      resolve_detected_question(run_or_outcome) ||
        (output && QuestionDetector.detect_question(output, task_id: task.id, role_id: role_run.role_id))

    if detected_question && task.stage_state != :blocked && is_nil(task.question_id) do
      case Rail.Pipeline.register_question(task, role_run, detected_question) do
        {:ok, %Rail.Pipeline.Schemas.Question{}} ->
          {Repo.get!(Task, task.id), Repo.get!(RoleRun, role_run.id)}

        _other ->
          {task, role_run}
      end
    else
      {task, role_run}
    end
  end

  defp resolve_settle_outcome(%Task{stage_state: :blocked, question_id: q_id}, role_run, _code, _error)
       when is_binary(q_id) do
    {%{}, role_run}
  end

  defp resolve_settle_outcome(task, role_run, 0, _error) do
    handle_clean_exit(task, role_run)
  end

  defp resolve_settle_outcome(task, role_run, exit_code, error) do
    handle_failed_exit(task, role_run, error, exit_code)
  end

  defp maybe_refresh_rebase_mergeability(%Task{} = updated_task, %Task{is_rebasing: true}, 0, opts) do
    case Rail.Pipeline.refresh_mergeability(updated_task, opts) do
      {:ok, refreshed} -> refreshed
      _failure -> updated_task
    end
  end

  defp maybe_refresh_rebase_mergeability(%Task{} = updated_task, _task, _exit_code, _opts) do
    updated_task
  end

  defp handle_clean_exit(%Task{is_rebasing: true} = task, role_run) do
    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{auto_retries: 0})
      |> Repo.update()

    attrs = %{
      is_rebasing: false,
      stage_state: task.stage_state_before_rebase || :queued,
      stage_state_before_rebase: nil,
      retry_after: nil,
      error: nil
    }

    {attrs, role_run}
  end

  defp handle_clean_exit(%Task{stage: :product} = task, role_run) do
    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{auto_retries: 0})
      |> Repo.update()

    target_stage =
      case Roles.role_for_stage(task.project_id, :design) do
        {:ok, _role} -> :design
        _no_designer -> :architect
      end

    attrs = %{
      stage: target_stage,
      stage_state: :queued,
      retry_after: nil,
      error: nil
    }

    {attrs, role_run}
  end

  defp handle_clean_exit(%Task{stage: :architect} = task, role_run) do
    has_plan? = Repo.exists?(from p in Plan, where: p.task_id == ^task.id)

    if has_plan? do
      {:ok, role_run} =
        role_run
        |> RoleRun.changeset(%{auto_retries: 0})
        |> Repo.update()

      attrs = %{
        stage_state: :awaiting_approval,
        retry_after: nil,
        error: nil
      }

      {attrs, role_run}
    else
      error_msg = "Architect exited 0 without writing a plan file."

      attrs = %{
        stage_state: :failed,
        error: error_msg,
        retry_after: nil
      }

      {attrs, role_run}
    end
  end

  defp handle_clean_exit(%Task{stage: :engineer} = _task, role_run) do
    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{auto_retries: 0})
      |> Repo.update()

    attrs = %{
      stage: :review,
      stage_state: :queued,
      retry_after: nil,
      error: nil
    }

    {attrs, role_run}
  end

  defp handle_clean_exit(%Task{stage: stage} = task, role_run) when stage in [:review, :qa, :qa_lead] do
    handle_gate_exit(task, role_run)
  end

  defp handle_clean_exit(%Task{} = _task, role_run) do
    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{auto_retries: 0})
      |> Repo.update()

    attrs = %{
      stage_state: :awaiting_approval,
      retry_after: nil,
      error: nil
    }

    {attrs, role_run}
  end

  defp handle_failed_exit(%Task{} = _task, role_run, error, exit_code) do
    error_msg = error || "Exited with code #{exit_code}"
    auto_retries = role_run.auto_retries || 0

    if RunFailure.transient?(error_msg) and auto_retries < RunFailure.max_auto_retries() do
      new_retries = auto_retries + 1
      delay_sec = RunFailure.retry_delay(new_retries) || 15
      retry_after = DateTime.shift(DateTime.utc_now(), second: delay_sec)

      {:ok, updated_role_run} =
        role_run
        |> RoleRun.changeset(%{auto_retries: new_retries})
        |> Repo.update()

      attrs = %{
        stage_state: :queued,
        retry_after: retry_after,
        error: error_msg
      }

      {attrs, updated_role_run}
    else
      attrs = %{
        stage_state: :failed,
        error: error_msg,
        retry_after: nil
      }

      {attrs, role_run}
    end
  end

  defp handle_gate_exit(%Task{} = task, %RoleRun{} = role_run) do
    {head_sha, dirty_digest} = resolve_fingerprint(task, role_run)

    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{
        auto_retries: 0,
        stage_fingerprint_head_sha: head_sha,
        stage_fingerprint_dirty_digest: dirty_digest
      })
      |> Repo.update()

    gate_role_id = role_run.role_id
    reports = task.outstanding_reports || []
    updated_reports = if gate_role_id in reports, do: reports, else: Enum.reverse([gate_role_id | Enum.reverse(reports)])
    verdict = StageVerdict.parse(role_run.output)

    case verdict.verdict do
      :passed ->
        handle_gate_passed(task, role_run, updated_reports, head_sha)

      :changes_requested ->
        handle_gate_changes_requested(task, role_run, gate_role_id, updated_reports)

      :unclear ->
        handle_gate_unclear(role_run, gate_role_id, updated_reports)
    end
  end

  defp handle_gate_passed(task, role_run, updated_reports, head_sha) do
    next_stage =
      case task.stage do
        :review ->
          :qa

        :qa ->
          :qa_lead

        :qa_lead ->
          case Roles.role_for_stage(task.project_id, :demo) do
            {:ok, _role} -> :demo
            _no_demo -> :ready_to_merge
          end
      end

    next_stage_state = if next_stage == :ready_to_merge, do: :awaiting_approval, else: :queued

    if (task.rework_cycles || 0) > 0 and next_stage != :ready_to_merge and head_sha != nil do
      maybe_append_evidence_line_to_next_stage(task, next_stage, head_sha)
    end

    attrs = %{
      stage: next_stage,
      stage_state: next_stage_state,
      outstanding_reports: updated_reports,
      retry_after: nil,
      error: nil
    }

    {attrs, role_run}
  end

  defp handle_gate_changes_requested(task, role_run, gate_role_id, updated_reports) do
    rework_base = task.rework_budget_base || 0
    total_rework = (task.rework_cycles || 0) - rework_base
    cycles_by_gate = task.rework_cycles_by_gate || %{}
    per_gate = Map.get(cycles_by_gate, gate_role_id, 0)
    rework_exhausted = total_rework >= 5 or per_gate >= 3

    if rework_exhausted do
      role_name = resolve_role_name(gate_role_id)
      by_gate_count = per_gate
      cycle_word = if by_gate_count == 1, do: "cycle", else: "cycles"

      error_msg =
        "#{role_name} is still requesting changes after #{by_gate_count} rework #{cycle_word}. " <>
          "Read the findings and decide: Send back to Engineer to have them addressed, " <>
          "or Skip to take the change as it is and go straight to the merge."

      attrs = %{
        stage_state: :awaiting_approval,
        outstanding_reports: updated_reports,
        retry_after: nil,
        error: error_msg
      }

      {attrs, role_run}
    else
      new_total_rework = (task.rework_cycles || 0) + 1
      new_cycles_by_gate = Map.put(cycles_by_gate, gate_role_id, per_gate + 1)
      role_name = resolve_role_name(gate_role_id)
      findings = String.trim(role_run.output || "")
      carried = build_carried_gate_reports(task, except: gate_role_id)

      note =
        "Findings from #{role_name} on the change you just pushed (rework #{new_total_rework} of 5). " <>
          "Address every finding, nits included, and the ones marked pre-existing rather than caused by this change too - " <>
          "nobody else picks those up, so leaving one loses it. Work in the same worktree on the same branch, " <>
          "run the project's checks from the top, push to the existing pull request, and say what you changed. " <>
          "Where you disagree with a finding, say why rather than silently leaving it.\n\n" <>
          findings <> carried

      case Roles.role_for_stage(task.project_id, :engineer) do
        {:ok, eng_role} ->
          update_or_create_engineer_pending_answer(task.id, eng_role.id, note)

        _other ->
          :ok
      end

      attrs = %{
        stage: :engineer,
        stage_state: :queued,
        rework_cycles: new_total_rework,
        rework_cycles_by_gate: new_cycles_by_gate,
        outstanding_reports: [],
        retry_after: nil,
        error: nil
      }

      {attrs, role_run}
    end
  end

  defp handle_gate_unclear(role_run, gate_role_id, updated_reports) do
    role_name = resolve_role_name(gate_role_id)

    error_msg =
      "#{role_name} ended without a clear verdict. " <>
        "Read its report, then Send back to Engineer or Skip to the merge."

    attrs = %{
      stage_state: :awaiting_approval,
      outstanding_reports: updated_reports,
      retry_after: nil,
      error: error_msg
    }

    {attrs, role_run}
  end

  defp resolve_fingerprint(%Task{worktree_path: path}, role_run) when is_binary(path) do
    case Git.branch_fingerprint(path) do
      %{head_sha: sha, dirty_digest: digest} ->
        {sha, digest}

      _other ->
        {role_run.stage_fingerprint_head_sha, role_run.stage_fingerprint_dirty_digest}
    end
  end

  defp resolve_fingerprint(_task, role_run) do
    {role_run.stage_fingerprint_head_sha, role_run.stage_fingerprint_dirty_digest}
  end

  defp resolve_role_name(role_id) do
    case Repo.get(Role, role_id) do
      %Role{name: name} when is_binary(name) and name != "" -> name
      _other -> to_string(role_id)
    end
  end

  defp update_or_create_engineer_pending_answer(task_id, engineer_role_id, note) do
    case Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^engineer_role_id) do
      %RoleRun{} = existing ->
        pending = existing.pending_answer
        new_pending = if pending && String.trim(pending) != "", do: "#{pending}\n\n#{note}", else: note

        existing
        |> RoleRun.changeset(%{pending_answer: new_pending, auto_retries: 0})
        |> Repo.update!()

      nil ->
        %RoleRun{}
        |> RoleRun.changeset(%{
          task_id: task_id,
          role_id: engineer_role_id,
          status: :finished,
          auto_retries: 0,
          pending_answer: note,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()
    end
  end

  defp maybe_append_evidence_line_to_next_stage(task, next_stage, head_sha) do
    case Roles.role_for_stage(task.project_id, next_stage) do
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

        case Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^next_role.id) do
          %RoleRun{} = existing ->
            pending = existing.pending_answer

            new_pending =
              if pending && String.trim(pending) != "", do: "#{pending}\n\n#{evidence_note}", else: evidence_note

            existing
            |> RoleRun.changeset(%{pending_answer: new_pending})
            |> Repo.update!()

          nil ->
            %RoleRun{}
            |> RoleRun.changeset(%{
              task_id: task.id,
              role_id: next_role.id,
              status: :finished,
              pending_answer: evidence_note,
              started_at: DateTime.utc_now()
            })
            |> Repo.insert!()
        end

      _other ->
        :ok
    end
  end

  defp update_role_run(role_run, exit_code, error, output, usage) do
    new_status =
      if role_run.status == :blocked_on_input do
        :blocked_on_input
      else
        :finished
      end

    attrs = %{
      status: new_status,
      completed_at: role_run.completed_at || DateTime.utc_now(),
      exit_code: exit_code,
      error: error,
      output: output
    }

    attrs = if usage, do: Map.put(attrs, :usage, usage), else: attrs

    role_run
    |> RoleRun.changeset(attrs)
    |> Repo.update()
  end

  defp resolve_detected_question(%{detected_question: %QuestionDetector{} = q}), do: q
  defp resolve_detected_question(%{"detected_question" => %QuestionDetector{} = q}), do: q
  defp resolve_detected_question(_other), do: nil

  defp maybe_finish_run(%Run{status: status} = run) when status != :finished do
    run |> Run.changeset(%{status: :finished}) |> Repo.update()
  end

  defp maybe_finish_run(%{run: %Run{status: status} = run}) when status != :finished do
    run |> Run.changeset(%{status: :finished}) |> Repo.update()
  end

  defp maybe_finish_run(_other), do: :ok

  defp resolve_exit_code(%{exit_code: code}, _role_run) when is_integer(code), do: code
  defp resolve_exit_code(%{"exit_code" => code}, _role_run) when is_integer(code), do: code
  defp resolve_exit_code(_outcome, %RoleRun{exit_code: code}) when is_integer(code), do: code
  defp resolve_exit_code(_outcome, _role_run), do: 0

  defp resolve_error(%{error: err}, _role_run) when is_binary(err), do: err
  defp resolve_error(%{"error" => err}, _role_run) when is_binary(err), do: err
  defp resolve_error(_outcome, %RoleRun{error: err}) when is_binary(err), do: err
  defp resolve_error(_outcome, _role_run), do: nil

  defp resolve_output(%{output: out}, _role_run) when is_binary(out), do: out
  defp resolve_output(%{"output" => out}, _role_run) when is_binary(out), do: out
  defp resolve_output(_outcome, %RoleRun{output: out}) when is_binary(out), do: out
  defp resolve_output(_outcome, _role_run), do: nil

  defp resolve_usage(%{usage: %TaskUsage{} = usage}, _role_run), do: Map.from_struct(usage)
  defp resolve_usage(%{usage: usage}, _role_run) when is_map(usage), do: usage
  defp resolve_usage(%{"usage" => %TaskUsage{} = usage}, _role_run), do: Map.from_struct(usage)
  defp resolve_usage(%{"usage" => usage}, _role_run) when is_map(usage), do: usage
  defp resolve_usage(_outcome, _role_run), do: nil

  defp resolve_task(%Task{} = task), do: task
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil

  defp resolve_role_run(%RoleRun{} = role_run), do: role_run
  defp resolve_role_run(id) when is_binary(id), do: Repo.get(RoleRun, id)
  defp resolve_role_run(_other), do: nil
end
