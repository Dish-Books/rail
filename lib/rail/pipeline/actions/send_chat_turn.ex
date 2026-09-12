defmodule Rail.Pipeline.Actions.SendChatTurn do
  @moduledoc """
  Dispatches or queues an interactive human chat turn to an agent role on a task.

  Supported delivery modes:
  - `:immediate` (default): dispatches immediately if the task is idle; holds if busy.
  - `:when_finished`: holds the message on the run until the active pipeline run pauses.
  - `:stop_and_send`: stops any active child process on the task, interrupts the current run,
    and immediately dispatches the chat turn.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Scope

  @valid_delivery_modes [:immediate, :when_finished, :stop_and_send]

  @doc """
  Sends a chat turn with the given delivery options.
  """
  def send_chat_turn(%Scope{} = scope, task_or_id, role_id, text, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         {:ok, %Task{} = task} <- resolve_task(task_or_id),
         {:ok, %Role{} = role} <- resolve_role(role_id),
         run = resolve_run(task.id, role.id),
         :ok <- validate_can_chat(run),
         {:ok, trimmed_text} <- validate_message(text),
         delivery = Keyword.get(opts, :delivery, :immediate),
         :ok <- validate_delivery_mode(delivery) do
      do_send_chat_turn(task, role, run, trimmed_text, delivery, opts)
    end
  end

  def send_chat_turn(%Scope{} = scope, task_or_id, role_id, text) do
    send_chat_turn(scope, task_or_id, role_id, text, [])
  end

  def send_chat_turn(task_or_id, role_id, text, opts) when is_list(opts) do
    send_chat_turn(Scope.for_system(), task_or_id, role_id, text, opts)
  end

  def send_chat_turn(task_or_id, role_id, text) do
    send_chat_turn(Scope.for_system(), task_or_id, role_id, text, [])
  end

  @doc """
  Executes the dispatch of a chat turn for a task and role.
  Prepares worktree, captures before-fingerprint, constructs prompt and argv,
  and spawns the runner process as a chat turn.
  """
  def dispatch_chat_turn(%Task{} = task, %Role{} = role, %Run{} = run, opts \\ []) do
    if Keyword.get(opts, :async, true) do
      caller = self()

      case Elixir.Task.Supervisor.start_child(Rail.TaskSupervisor, fn ->
             allow_sandbox(caller)
             execute_chat_turn(task, role, run, opts)
           end) do
        {:ok, _pid} ->
          {:ok, task}

        # coveralls-ignore-start
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
    else
      execute_chat_turn(task, role, run, opts)
    end
  end

  @doc """
  Dispatches the earliest queued pending chat message for a task if the task is not currently busy.
  """
  def maybe_dispatch_queued_pending_chat(%Task{} = task, opts \\ []) do
    task = Repo.get(Task, task.id) || task

    if Task.busy?(task) do
      :ok
    else
      query =
        from r in Run,
          where: r.task_id == ^task.id and not is_nil(r.pending_chat) and r.pending_chat != "",
          order_by: [asc: r.inserted_at],
          limit: 1

      case Repo.one(query) do
        %Run{} = queued_run ->
          case Roles.get_role(id: queued_run.role_id) do
            {:ok, %Role{} = queued_role} ->
              dispatch_chat_turn(task, queued_role, queued_run, opts)

            {:error, :role_not_found} ->
              :ok
          end

        nil ->
          :ok
      end
    end
  end

  defp authorize_scope(%Scope{system: true}), do: :ok
  defp authorize_scope(%Scope{user: %{}}), do: :ok
  defp authorize_scope(_scope), do: {:error, :not_authorized}

  defp resolve_task(%Task{} = task), do: resolve_task(task.id)

  defp resolve_task(id) when is_binary(id) do
    case Repo.get(Task, id) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :not_found}
    end
  end

  defp resolve_task(_other), do: {:error, :not_found}

  defp resolve_role(%Role{} = role), do: {:ok, role}

  defp resolve_role(id) when is_binary(id) do
    case Roles.get_role(id: id) do
      {:ok, %Role{} = role} -> {:ok, role}
      {:error, :role_not_found} -> {:error, {:role_not_found, id}}
    end
  end

  defp resolve_role(_other), do: {:error, :role_not_found}

  defp resolve_run(task_id, role_id) do
    Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_id)
  end

  defp validate_can_chat(nil), do: {:error, :chat_unavailable}

  defp validate_can_chat(%Run{} = run) do
    if Run.can_chat?(run) do
      :ok
    else
      {:error, :chat_unavailable}
    end
  end

  defp validate_message(text) when is_binary(text) do
    trimmed = String.trim(text)

    if trimmed == "" do
      {:error, :empty_message}
    else
      {:ok, trimmed}
    end
  end

  defp validate_message(_other), do: {:error, :empty_message}

  defp validate_delivery_mode(mode) when mode in @valid_delivery_modes, do: :ok
  defp validate_delivery_mode(other), do: {:error, {:invalid_delivery_mode, other}}

  defp do_send_chat_turn(task, role, run, text, delivery, opts) do
    record_human_transcript(run.id, text)
    task_is_busy = Task.busy?(task)

    case delivery do
      :when_finished ->
        hold_pending_chat(task, run, text)

      :immediate ->
        if task_is_busy do
          hold_pending_chat(task, run, text)
        else
          dispatch_chat_turn_now(task, role, run, text, opts)
        end

      :stop_and_send ->
        handle_stop_and_send(task, role, run, text, opts)
    end
  end

  defp record_human_transcript(run_id, text) do
    text
    |> String.split("\n")
    |> Enum.each(fn line ->
      Runs.append_run_event(run_id, "[human] #{line}")
    end)
  end

  defp hold_pending_chat(task, run, text) do
    new_pending = append_pending(run.pending_chat, text)

    {:ok, _run} =
      run
      |> Run.changeset(%{pending_chat: new_pending})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :chat_queued})
    {:ok, :queued, task}
  end

  defp dispatch_chat_turn_now(task, role, run, text, opts) do
    new_pending = append_pending(run.pending_chat, text)

    {:ok, updated_run} =
      run
      |> Run.changeset(%{pending_chat: new_pending})
      |> Repo.update()

    case dispatch_chat_turn(task, role, updated_run, opts) do
      {:ok, %OsProcess{task: %Task{} = updated_task}} ->
        {:ok, :sent, updated_task}

      {:ok, %Task{} = updated_task} ->
        {:ok, :sent, updated_task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_stop_and_send(task, role, run, text, opts) do
    if Task.busy?(task) do
      interrupt_active_run(task, role)
    end

    # Refresh task and run after potential stop
    task = Repo.get!(Task, task.id)
    run = Repo.get!(Run, run.id)
    dispatch_chat_turn_now(task, role, run, text, opts)
  end

  defp interrupt_active_run(task, target_role) do
    cond do
      is_binary(task.active_chat_role_id) ->
        interrupt_active_chat(task, target_role)

      task.stage_state == :running or Runs.running?(task.id) ->
        interrupt_active_stage(task, target_role)

      # coveralls-ignore-start
      true ->
        :ok
        # coveralls-ignore-stop
    end
  end

  defp interrupt_active_chat(task, target_role) do
    stopped_role_id = task.active_chat_role_id

    if stopped_role_id == target_role.id do
      record_same_role_chat_stop(task.id, stopped_role_id)
    else
      record_different_role_chat_stop(task.id, stopped_role_id, target_role)
    end

    Runs.stop_os_process(task.id)
  end

  defp record_same_role_chat_stop(task_id, role_id) do
    case Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^role_id) do
      %Run{} = run ->
        Runs.append_run_event(run.id, "[rail] Chat turn stopped by user.")

      # coveralls-ignore-start
      nil ->
        :ok
        # coveralls-ignore-stop
    end
  end

  defp record_different_role_chat_stop(task_id, stopped_role_id, target_role) do
    case Repo.one(from r in Run, where: r.task_id == ^task_id and r.role_id == ^stopped_role_id) do
      %Run{} = stopped_run ->
        stopped_run
        |> Run.changeset(%{
          pending_chat: nil,
          chat_fingerprint_head_sha: nil,
          chat_fingerprint_dirty_digest: nil
        })
        |> Repo.update!()

        Runs.append_run_event(
          stopped_run.id,
          "[rail] Chat turn stopped by user to send chat to #{target_role.name || target_role.id}."
        )

      nil ->
        :ok
    end
  end

  defp interrupt_active_stage(task, target_role) do
    stage = if task.is_rebasing, do: :engineer, else: task.stage

    with {:ok, stage_role} <- Roles.get_role(project_id: task.project_id, stage: stage),
         %Run{} = stage_run <-
           Repo.one(from r in Run, where: r.task_id == ^task.id and r.role_id == ^stage_role.id) do
      record_stage_interrupt_event(stage_role, stage_run, target_role)
    else
      _other -> :ok
    end

    task
    |> Task.changeset(%{stage_state: :queued, error: nil})
    |> Repo.update!()

    Runs.stop_os_process(task.id)
  end

  defp record_stage_interrupt_event(stage_role, stage_run, target_role) do
    if stage_role.id == target_role.id do
      Runs.append_run_event(stage_run.id, "[rail] Run stopped by user to restart with message.")
    else
      Runs.append_run_event(
        stage_run.id,
        "[rail] Run stopped by user to send chat to #{target_role.name || target_role.id}."
      )
    end
  end

  defp execute_chat_turn(task, role, run, opts) do
    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        task = Repo.get(Task, task.id) || task
        run = Repo.get(Run, run.id) || run

        case Git.get_or_create_worktree(project, task) do
          {:ok, resolved_wt_path} ->
            proceed_with_chat_execution(task, project, role, run, resolved_wt_path, opts)

          {:error, reason} ->
            handle_chat_worktree_failure(task, run, reason)
        end

      nil ->
        {:error, :project_not_found}
    end
  end

  defp proceed_with_chat_execution(task, _project, role, run, worktree_path, opts) do
    {head_sha, dirty_digest} =
      case Git.branch_fingerprint(worktree_path) do
        %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
        _other -> {nil, nil}
      end

    {:ok, updated_run} =
      run
      |> Run.changeset(%{
        chat_fingerprint_head_sha: head_sha,
        chat_fingerprint_dirty_digest: dirty_digest
      })
      |> Repo.update()

    {:ok, updated_task} =
      task
      |> Task.changeset(%{
        active_chat_role_id: role.id,
        worktree_path: worktree_path
      })
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :chat_dispatched})

    message = updated_run.pending_chat || Keyword.get(opts, :text, "")
    chat_prompt = Runs.chat_prompt(message)

    argv =
      Runs.build_args(
        backend: role.backend,
        prompt: chat_prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        read_only: false,
        system_prompt: role.system_prompt,
        conversation_id: updated_run.conversation_id,
        work_dir: worktree_path
      )

    case Runs.start_os_process(updated_run, argv, is_chat: true) do
      {:ok, %OsProcess{} = os_process} ->
        {:ok, os_process}

      {:error, {:spawn_failed, reason, _task}} ->
        updated_task
        |> Task.changeset(%{active_chat_role_id: nil})
        |> Repo.update!()

        updated_run
        |> Run.changeset(%{
          chat_fingerprint_head_sha: nil,
          chat_fingerprint_dirty_digest: nil
        })
        |> Repo.update!()

        Runs.append_run_event(updated_run.id, "[rail] That turn was not delivered: #{inspect(reason)}")
        Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :chat_failed})

        {:error, {:spawn_failed, reason}}
    end
  end

  defp handle_chat_worktree_failure(task, run, reason) do
    task
    |> Task.changeset(%{active_chat_role_id: nil})
    |> Repo.update!()

    run
    |> Run.changeset(%{
      chat_fingerprint_head_sha: nil,
      chat_fingerprint_dirty_digest: nil
    })
    |> Repo.update!()

    Runs.append_run_event(run.id, "[rail] That turn was not delivered: #{inspect(reason)}")
    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :chat_failed})

    {:error, {:worktree_failed, reason}}
  end

  defp append_pending(nil, text), do: text
  defp append_pending(existing, text), do: "#{existing}\n\n#{text}"

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
