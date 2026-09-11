defmodule Rail.Pipeline.Actions.DispatchNow do
  @moduledoc """
  Action that synchronously evaluates a specific task for immediate dispatch.

  Verifies:
  - Caller authorization via `Rail.Scope`.
  - Dispatch is not globally or explicitly disabled.
  - Task exists and is in `:queued` stage state.
  - Task is not waiting on retry backoff (`retry_after == nil || retry_after <= DateTime.utc_now()`).
  - Project and role for current stage (or engineer if rebasing) exist.
  - Available concurrency slots exist for the role.
  """

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline.Queue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Synchronously evaluates and dispatches a single task.
  """
  def dispatch_now(%Scope{} = scope, task_or_id, opts) when is_list(opts) do
    cond do
      not authorized_scope?(scope) ->
        {:error, :not_authorized}

      dispatch_disabled?(opts) ->
        {:error, :dispatch_disabled}

      true ->
        case resolve_task(task_or_id) do
          {:ok, task} -> do_dispatch_now(task, opts)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def dispatch_now(%Scope{} = scope, task_or_id) do
    dispatch_now(scope, task_or_id, [])
  end

  def dispatch_now(task_or_id, opts) when is_list(opts) do
    dispatch_now(Scope.for_system(), task_or_id, opts)
  end

  def dispatch_now(task_or_id) do
    dispatch_now(Scope.for_system(), task_or_id, [])
  end

  defp authorized_scope?(%Scope{system: true}), do: true
  defp authorized_scope?(%Scope{user: %{}}), do: true
  defp authorized_scope?(_scope), do: false

  defp do_dispatch_now(%Task{} = task, opts) do
    cond do
      task.stage_state != :queued ->
        {:error, {:not_queued, task.stage_state}}

      waiting_to_retry?(task) ->
        {:error, :waiting_to_retry}

      true ->
        evaluate_and_dispatch(task, opts)
    end
  end

  defp evaluate_and_dispatch(%Task{} = task, opts) do
    stage_to_find = if task.is_rebasing, do: :engineer, else: task.stage

    with {:ok, project} <- fetch_project(task.project_id),
         {:ok, role} <- Roles.get_role(project_id: project.id, stage: stage_to_find),
         :ok <- verify_available_slots(project.id, role) do
      dispatch_hook = Keyword.get(opts, :dispatch_hook, &default_dispatch_hook/2)
      dispatch_hook.(task, role)
    end
  end

  defp dispatch_disabled?(opts) do
    case Keyword.fetch(opts, :dispatch_disabled) do
      {:ok, disabled?} ->
        disabled?

      :error ->
        Application.get_env(:rail, :no_dispatch, false) ||
          System.get_env("RAIL_NO_DISPATCH") == "1"
    end
  end

  defp waiting_to_retry?(%Task{retry_after: nil}), do: false

  defp waiting_to_retry?(%Task{retry_after: %DateTime{} = retry_after}) do
    DateTime.after?(retry_after, DateTime.utc_now())
  end

  defp fetch_project(project_id) do
    case Repo.get(Project, project_id) do
      %Project{} = project -> {:ok, project}
      nil -> {:error, :project_not_found}
    end
  end

  defp verify_available_slots(project_id, %Role{} = role) do
    if Queue.available_slots(project_id, role) > 0 do
      :ok
    else
      {:error, :no_available_slots}
    end
  end

  defp resolve_task(%Task{} = task), do: {:ok, task}
  defp resolve_task(id) when is_binary(id), do: resolve_task_by_id(id)
  defp resolve_task(_other), do: {:error, :not_found}

  defp resolve_task_by_id(id) do
    case Repo.get(Task, id) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :not_found}
    end
  end

  defp default_dispatch_hook(%Task{} = task, _role) do
    caller = self()

    case Elixir.Task.Supervisor.start_child(Rail.TaskSupervisor, fn ->
           allow_sandbox(caller)
           Rail.Pipeline.start_stage_run(task)
         end) do
      {:ok, _pid} ->
        {:ok, task}

      # coveralls-ignore-start
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  # coveralls-ignore-start (test sandbox fallback)
  defp allow_sandbox(caller_pid) do
    if Code.ensure_loaded?(Sandbox) and is_pid(caller_pid) do
      Sandbox.allow(Repo, caller_pid, self())
    end
  rescue
    _error -> :ok
  end

  # coveralls-ignore-stop
end
