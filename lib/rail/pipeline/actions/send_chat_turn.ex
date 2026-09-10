defmodule Rail.Pipeline.Actions.SendChatTurn do
  @moduledoc """
  Dispatches or queues an interactive human chat turn to an agent role on a task.

  Supported delivery modes:
  - `:immediate` (default): dispatches immediately if the task is idle; holds if busy.
  - `:when_finished`: holds the message on the role run until the active pipeline run pauses.
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
  alias Rail.Runs.ArgvBuilder
  alias Rail.Runs.PromptBuilder
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Scope

  @valid_delivery_modes [:immediate, :when_finished, :stop_and_send]

  @doc """
  Sends a chat turn with the given delivery options.
  """
  def send_chat_turn(%Scope{} = scope, task_or_id, role_id, text, opts) when is_list(opts) do
    with :ok <- authorize_scope(scope),
         {:ok, %Task{} = task} <- resolve_task(task_or_id),
         {:ok, %Role{} = role} <- resolve_role(role_id),
         role_run = resolve_role_run(task.id, role.id),
         :ok <- validate_can_chat(role_run),
         {:ok, trimmed_text} <- validate_message(text),
         delivery = Keyword.get(opts, :delivery, :immediate),
         :ok <- validate_delivery_mode(delivery) do
      do_send_chat_turn(task, role, role_run, trimmed_text, delivery, opts)
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
  and spawns the runner process with kind `:chat`.
  """
  def dispatch_chat_turn(%Task{} = task, %Role{} = role, %RoleRun{} = role_run, opts \\ []) do
    if Keyword.get(opts, :async, true) do
      caller = self()

      case Elixir.Task.Supervisor.start_child(Rail.TaskSupervisor, fn ->
             allow_sandbox(caller)
             execute_chat_turn(task, role, role_run, opts)
           end) do
        {:ok, _pid} ->
          {:ok, task}

        # coveralls-ignore-start
        {:error, reason} ->
          {:error, reason}
          # coveralls-ignore-stop
      end
    else
      execute_chat_turn(task, role, role_run, opts)
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
        from r in RoleRun,
          where: r.task_id == ^task.id and not is_nil(r.pending_chat) and r.pending_chat != "",
          order_by: [asc: r.inserted_at],
          limit: 1

      case Repo.one(query) do
        %RoleRun{} = queued_run ->
          case Repo.get(Role, queued_run.role_id) do
            %Role{} = queued_role ->
              dispatch_chat_turn(task, queued_role, queued_run, opts)

            nil ->
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
    case Repo.get(Role, id) do
      %Role{} = role -> {:ok, role}
      nil -> {:error, {:role_not_found, id}}
    end
  end

  defp resolve_role(_other), do: {:error, :role_not_found}

  defp resolve_role_run(task_id, role_id) do
    Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_id)
  end

  defp validate_can_chat(nil), do: {:error, :chat_unavailable}

  defp validate_can_chat(%RoleRun{} = role_run) do
    if RoleRun.can_chat?(role_run) do
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

  defp do_send_chat_turn(task, role, role_run, text, delivery, opts) do
    record_human_transcript(role_run.id, text)
    task_is_busy = Task.busy?(task)

    case delivery do
      :when_finished ->
        hold_pending_chat(task, role_run, text)

      :immediate ->
        if task_is_busy do
          hold_pending_chat(task, role_run, text)
        else
          dispatch_chat_turn_now(task, role, role_run, text, opts)
        end

      :stop_and_send ->
        handle_stop_and_send(task, role, role_run, text, opts)
    end
  end

  defp record_human_transcript(role_run_id, text) do
    text
    |> String.split("\n")
    |> Enum.each(fn line ->
      Runs.append_run_event(role_run_id, "[human] #{line}")
    end)
  end

  defp hold_pending_chat(task, role_run, text) do
    new_pending = append_pending(role_run.pending_chat, text)

    {:ok, _role_run} =
      role_run
      |> RoleRun.changeset(%{pending_chat: new_pending})
      |> Repo.update()

    Rail.Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :chat_queued})
    {:ok, :queued, task}
  end

  defp dispatch_chat_turn_now(task, role, role_run, text, opts) do
    new_pending = append_pending(role_run.pending_chat, text)

    {:ok, updated_role_run} =
      role_run
      |> RoleRun.changeset(%{pending_chat: new_pending})
      |> Repo.update()

    case dispatch_chat_turn(task, role, updated_role_run, opts) do
      {:ok, %{task: updated_task}} ->
        {:ok, :sent, updated_task}

      {:ok, %Task{} = updated_task} ->
        {:ok, :sent, updated_task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_stop_and_send(task, role, role_run, text, opts) do
    if Task.busy?(task) do
      interrupt_active_run(task, role)
    end

    # Refresh task and role_run after potential stop
    task = Repo.get!(Task, task.id)
    role_run = Repo.get!(RoleRun, role_run.id)
    dispatch_chat_turn_now(task, role, role_run, text, opts)
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

    Runs.stop_run(task.id)
  end

  defp record_same_role_chat_stop(task_id, role_id) do
    case Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^role_id) do
      %RoleRun{} = run ->
        Runs.append_run_event(run.id, "[rail] Chat turn stopped by user.")

      # coveralls-ignore-start
      nil ->
        :ok
        # coveralls-ignore-stop
    end
  end

  defp record_different_role_chat_stop(task_id, stopped_role_id, target_role) do
    case Repo.one(from r in RoleRun, where: r.task_id == ^task_id and r.role_id == ^stopped_role_id) do
      %RoleRun{} = stopped_run ->
        stopped_run
        |> RoleRun.changeset(%{
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

    with {:ok, stage_role} <- Roles.role_for_stage(task.project_id, stage),
         %RoleRun{} = stage_role_run <-
           Repo.one(from r in RoleRun, where: r.task_id == ^task.id and r.role_id == ^stage_role.id) do
      record_stage_interrupt_event(stage_role, stage_role_run, target_role)
    else
      _other -> :ok
    end

    task
    |> Task.changeset(%{stage_state: :queued, error: nil})
    |> Repo.update!()

    Runs.stop_run(task.id)
  end

  defp record_stage_interrupt_event(stage_role, stage_role_run, target_role) do
    if stage_role.id == target_role.id do
      Runs.append_run_event(stage_role_run.id, "[rail] Run stopped by user to restart with message.")
    else
      Runs.append_run_event(
        stage_role_run.id,
        "[rail] Run stopped by user to send chat to #{target_role.name || target_role.id}."
      )
    end
  end

  defp execute_chat_turn(task, role, role_run, opts) do
    case Repo.get(Project, task.project_id) do
      %Project{} = project ->
        task = Repo.get(Task, task.id) || task
        role_run = Repo.get(RoleRun, role_run.id) || role_run
        base_branch = Keyword.get(opts, :base_branch) || project.default_branch || "main"
        worktree_name = task.worktree_name || task.id

        worktree_path =
          task.worktree_path ||
            Keyword.get(opts, :worktree_path) ||
            Path.join(project.clone_path, ".worktrees/#{worktree_name}")

        case Git.get_or_create_worktree(project.clone_path, worktree_path, worktree_name, base_branch: base_branch) do
          {:ok, resolved_wt_path} ->
            proceed_with_chat_execution(task, project, role, role_run, resolved_wt_path, opts)

          {:error, reason} ->
            handle_chat_worktree_failure(task, role_run, reason)
        end

      nil ->
        {:error, :project_not_found}
    end
  end

  defp proceed_with_chat_execution(task, _project, role, role_run, worktree_path, opts) do
    {head_sha, dirty_digest} =
      case Git.branch_fingerprint(worktree_path) do
        %{head_sha: sha, dirty_digest: digest} -> {sha, digest}
        _other -> {nil, nil}
      end

    {:ok, updated_role_run} =
      role_run
      |> RoleRun.changeset(%{
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

    message = updated_role_run.pending_chat || Keyword.get(opts, :text, "")
    chat_prompt = PromptBuilder.chat_prompt(message)

    argv =
      ArgvBuilder.build_argv(
        backend: role.cli_backend,
        prompt: chat_prompt,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        read_only: false,
        system_prompt: role.system_prompt,
        conversation_id: updated_role_run.conversation_id,
        work_dir: worktree_path
      )

    on_finished_cb = fn _run, outcome ->
      Rail.Pipeline.settle_chat_turn(updated_task.id, updated_role_run.id, outcome, opts)
    end

    spawner_opts =
      opts
      |> Keyword.put_new(:backend, role.cli_backend)
      |> Keyword.put_new(:cd, worktree_path)
      |> Keyword.put(:on_finished, on_finished_cb)

    case Runs.start_run(updated_role_run, :chat, argv, spawner_opts) do
      {:ok, run} ->
        {:ok, %{task: updated_task, role_run: updated_role_run, run: run}}

      {:error, reason} ->
        updated_task
        |> Task.changeset(%{active_chat_role_id: nil})
        |> Repo.update!()

        updated_role_run
        |> RoleRun.changeset(%{
          chat_fingerprint_head_sha: nil,
          chat_fingerprint_dirty_digest: nil
        })
        |> Repo.update!()

        Runs.append_run_event(updated_role_run.id, "[rail] That turn was not delivered: #{inspect(reason)}")
        Rail.Pipeline.broadcast_pipeline_changed(%{task_id: updated_task.id, event: :chat_failed})

        {:error, {:spawn_failed, reason}}
    end
  end

  defp handle_chat_worktree_failure(task, role_run, reason) do
    task
    |> Task.changeset(%{active_chat_role_id: nil})
    |> Repo.update!()

    role_run
    |> RoleRun.changeset(%{
      chat_fingerprint_head_sha: nil,
      chat_fingerprint_dirty_digest: nil
    })
    |> Repo.update!()

    Runs.append_run_event(role_run.id, "[rail] That turn was not delivered: #{inspect(reason)}")
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
