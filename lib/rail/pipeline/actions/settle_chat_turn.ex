defmodule Rail.Pipeline.Actions.SettleChatTurn do
  @moduledoc """
  Settles a completed interactive chat turn for an agent role on a task.
  - Clears `task.active_chat_role_id`.
  - Accumulates `chat_usage` on exit 0.
  - Detects worktree branch modifications:
    - Engineer modifications reset pipeline to Engineer `awaitingApproval` or queue Review (if reworked).
    - Other role modifications log notice without resetting the pipeline.
  - Logs failure on non-zero exit without disrupting the main stage pipeline.
  - Dispatches any queued `pending_chat` once the task is idle.
  """

  import Ecto.Query

  alias Rail.Domain.TaskUsage
  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @doc """
  Settles a finished chat turn for a task and role run.
  """
  def settle_chat_turn(task_target, role_run_target, run_or_outcome \\ %{}, opts \\ []) do
    with %Task{} = task <- resolve_task(task_target),
         %RoleRun{} = role_run <- resolve_role_run(role_run_target) do
      do_settle_chat_turn(task, role_run, run_or_outcome, opts)
    else
      _not_found -> {:error, :not_found}
    end
  end

  defp do_settle_chat_turn(%Task{} = task, %RoleRun{} = role_run, run_or_outcome, opts) do
    exit_code = resolve_exit_code(run_or_outcome, role_run)
    error = resolve_error(run_or_outcome, role_run)
    usage = resolve_usage(run_or_outcome)

    maybe_finish_run(run_or_outcome)

    before_head_sha = role_run.chat_fingerprint_head_sha
    before_dirty_digest = role_run.chat_fingerprint_dirty_digest

    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{
        chat_fingerprint_head_sha: nil,
        chat_fingerprint_dirty_digest: nil
      })
      |> Repo.update()

    {:ok, task} =
      task
      |> Task.changeset(%{active_chat_role_id: nil})
      |> Repo.update()

    {task, role_run} =
      if exit_code == 0 do
        handle_clean_chat_exit(task, role_run, usage, before_head_sha, before_dirty_digest, opts)
      else
        handle_failed_chat_exit(task, role_run, error, exit_code)
      end

    Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :chat_settled})

    Pipeline.maybe_dispatch_queued_pending_chat(task, opts)

    {:ok, task, role_run}
  end

  defp handle_clean_chat_exit(task, role_run, usage, before_head_sha, before_dirty_digest, opts) do
    current_chat_usage = role_run.chat_usage || %TaskUsage{}
    new_chat_usage = if usage, do: TaskUsage.add(current_chat_usage, usage), else: current_chat_usage

    {:ok, role_run} =
      role_run
      |> RoleRun.changeset(%{
        pending_chat: nil,
        chat_usage: new_chat_usage
      })
      |> Repo.update()

    {task, role_run} = check_branch_modification(task, role_run, before_head_sha, before_dirty_digest)
    check_design_manifest_modification(task, role_run, opts)
  end

  defp check_design_manifest_modification(task, role_run, opts) do
    role = role_for_run(role_run)
    before_stamp = Keyword.get(opts, :before_design_stamp)

    if is_struct(role, Role) and role.stage == :design and task.stage == :design and task.stage_state != :blocked and
         Keyword.has_key?(opts, :before_design_stamp) do
      after_stamp = Pipeline.design_manifest_stamp(task.worktree_path)

      if after_stamp == before_stamp do
        {task, role_run}
      else
        apply_design_manifest_chat(task, role_run, opts)
      end
    else
      {task, role_run}
    end
  end

  defp apply_design_manifest_chat(task, role_run, opts) do
    scope = Scope.for_system()

    case Pipeline.apply_design_manifest(scope, task, Keyword.put(opts, :require_new_version, false)) do
      {:ok, _design} ->
        {:ok, updated_task} =
          task
          |> Task.changeset(%{stage_state: :awaiting_approval, error: nil})
          |> Repo.update()

        Runs.append_run_event(role_run.id, "[rail] Design manifest changed during chat; design accepted.")
        {updated_task, role_run}

      {:error, reason} ->
        err_msg = if is_binary(reason), do: reason, else: inspect(reason)

        {:ok, updated_task} =
          task
          |> Task.changeset(%{stage_state: :failed, error: err_msg})
          |> Repo.update()

        Runs.append_run_event(
          role_run.id,
          "[rail] Design manifest changed during chat, but was turned down: #{err_msg}"
        )

        {updated_task, role_run}
    end
  end

  defp handle_failed_chat_exit(task, role_run, error, exit_code) do
    err_msg = error || "exit code #{exit_code}"
    Runs.append_run_event(role_run.id, "[rail] That turn was not delivered: #{err_msg}")
    {task, role_run}
  end

  defp check_branch_modification(task, role_run, before_head_sha, before_dirty_digest) do
    worktree_path = task.worktree_path

    if before_head_sha != nil and is_binary(worktree_path) and File.dir?(worktree_path) do
      after_fp = Git.branch_fingerprint(worktree_path)

      if after_fp != nil and (after_fp.head_sha != before_head_sha or after_fp.dirty_digest != before_dirty_digest) do
        apply_branch_modification(task, role_run, after_fp)
      else
        {task, role_run}
      end
    else
      {task, role_run}
    end
  end

  defp apply_branch_modification(task, role_run, after_fp) do
    role = role_for_run(role_run)

    if role && role.stage == :engineer do
      has_been_reworked = (task.rework_cycles || 0) > 0

      {:ok, updated_role_run} =
        role_run
        |> RoleRun.changeset(%{
          stage_fingerprint_head_sha: after_fp.head_sha,
          stage_fingerprint_dirty_digest: after_fp.dirty_digest
        })
        |> Repo.update()

      if has_been_reworked do
        Runs.append_run_event(role_run.id, "[rail] Branch modified during chat; queued for review.")

        maybe_append_reviewer_pending_answer(task, after_fp.head_sha)

        {:ok, updated_task} =
          task
          |> Task.changeset(%{
            stage: :review,
            stage_state: :queued,
            outstanding_reports: []
          })
          |> Repo.update()

        {updated_task, updated_role_run}
      else
        Runs.append_run_event(role_run.id, "[rail] Branch modified during chat; reset pipeline to Engineer.")

        {:ok, updated_task} =
          task
          |> Task.changeset(%{
            stage: :engineer,
            stage_state: :awaiting_approval,
            outstanding_reports: []
          })
          |> Repo.update()

        {updated_task, updated_role_run}
      end
    else
      Runs.append_run_event(
        role_run.id,
        "[rail] Changes were made to the branch, but only Engineer changes reset the pipeline."
      )

      {task, role_run}
    end
  end

  defp maybe_append_reviewer_pending_answer(task, head_sha) do
    case Roles.get_role(project_id: task.project_id, stage: :review) do
      {:ok, review_role} ->
        evidence_note =
          "The engineer has addressed the findings from your last pass on this branch. " <>
            "Re-read the diff as it stands now, check each finding you raised, and report anything still outstanding or newly introduced. " <>
            "End with your verdict line as usual.\n\n" <>
            "The reworked change is commit #{head_sha}. Every check you report on this pass must have been run against it: " <>
            "evidence produced before it describes a build that no longer exists, and carrying such a row forward is a false pass. " <>
            "Re-run what you carry, or say plainly that you did not."

        case Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^review_role.id) do
          %RoleRun{} = review_run ->
            if RoleRun.resumable?(review_run), do: Runs.append_pending_answer(review_run, evidence_note)

          nil ->
            :ok
        end

      _other ->
        :ok
    end
  end

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

  defp resolve_usage(%{usage: %TaskUsage{} = usage}), do: usage
  defp resolve_usage(%{usage: usage}) when is_map(usage), do: struct(TaskUsage, usage)
  defp resolve_usage(%{"usage" => %TaskUsage{} = usage}), do: usage
  defp resolve_usage(%{"usage" => usage}) when is_map(usage), do: struct(TaskUsage, usage)
  defp resolve_usage(_other), do: nil

  defp resolve_task(%Task{} = task), do: Repo.get(Task, task.id)
  defp resolve_task(id) when is_binary(id), do: Repo.get(Task, id)
  defp resolve_task(_other), do: nil

  defp role_for_run(%RoleRun{role_id: role_id}) do
    case Roles.get_role(id: role_id) do
      {:ok, %Role{} = role} -> role
      {:error, :role_not_found} -> nil
    end
  end

  defp resolve_role_run(%RoleRun{} = role_run), do: Repo.get(RoleRun, role_run.id)
  defp resolve_role_run(id) when is_binary(id), do: Repo.get(RoleRun, id)
  defp resolve_role_run(_other), do: nil
end
