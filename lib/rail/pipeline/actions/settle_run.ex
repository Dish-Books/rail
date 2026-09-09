defmodule Rail.Pipeline.Actions.SettleRun do
  @moduledoc """
  Settles finished agent runs, captures stage scratch artifacts, advances the pipeline,
  and classifies transient vs permanent failures with automatic retry backoff.
  """

  import Ecto.Query
  import Rail.Pipeline.Utils.Scratch

  alias Rail.Domain.RunFailure
  alias Rail.Domain.TaskUsage
  alias Rail.Pipeline.Schemas.Plan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
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
      do_settle_run(task, role_run, run_or_outcome, opts)
    else
      _not_found -> {:error, :not_found}
    end
  end

  defp do_settle_run(%Task{} = task, %RoleRun{} = role_run, run_or_outcome, opts) do
    exit_code = resolve_exit_code(run_or_outcome, role_run)
    error = resolve_error(run_or_outcome, role_run)
    output = resolve_output(run_or_outcome, role_run)
    usage = resolve_usage(run_or_outcome, role_run)

    maybe_finish_run(run_or_outcome)

    {:ok, role_run} = update_role_run(role_run, exit_code, error, output, usage)

    scratch_dir =
      Keyword.get(opts, :scratch_dir) ||
        Keyword.get(opts, :scratch_path) ||
        default_scratch_path(task.project_id, task.id)

    {:ok, task} = capture(task.stage, task, scratch_dir)

    {task_attrs, updated_role_run} =
      if exit_code == 0 do
        handle_clean_exit(task, role_run)
      else
        handle_failed_exit(task, role_run, error, exit_code)
      end

    {:ok, updated_task} =
      task
      |> Task.changeset(task_attrs)
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :run_settled})

    {:ok, updated_task, updated_role_run}
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

  defp update_role_run(role_run, exit_code, error, output, usage) do
    attrs = %{
      status: :finished,
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
