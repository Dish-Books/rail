defmodule Rail.Pipeline.Utils.DispatchMessage do
  @moduledoc """
  Sends whatever is queued on a run to the agent holding that conversation.

  The queued text is taken off the run as it goes out, so `pending_chat` means
  one thing only: a message the human has written that the agent has not seen.
  That is what lets someone type while the agent is still working — the message
  waits on the row rather than being appended to the turn already in flight — and
  what lets `stop_run/1` hand an undelivered message back to the composer.

  A dispatch that never reaches a process puts the text back, so a failed send
  degrades to a message that is still queued rather than one that is lost.
  """

  import Rail.Pipeline.Utils.PrepareWorktree
  import Rail.Pipeline.Utils.StartWorktreeSetup

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Dispatches `run`'s queued message.

  Spawns in the background by default. `async: false` runs it inline and returns
  `{:ok, os_process}`, which is what a caller that needs to see the spawn itself
  should pass.
  """
  def dispatch_message(%Run{} = run, opts \\ []) do
    if Keyword.get(opts, :async, true) do
      caller = self()

      Elixir.Task.Supervisor.start_child(Rail.TaskSupervisor, fn ->
        allow_sandbox(caller)
        execute(run, opts)
      end)

      {:ok, run}
    else
      execute(run, opts)
    end
  end

  # A worktree that still needs setting up gets that first, with the message left
  # queued: the setup's finish drains it.
  defp execute(%Run{} = run, opts) do
    with %Run{task: %Task{}, role: %Role{} = role} = run <- reload(run),
         %Project{} = project <- Repo.get(Project, run.task.project_id),
         {:ok, task, worktree_path} <- worktree(project, run.task) do
      case start_worktree_setup(%{run | task: task}) do
        :not_needed ->
          send_message(task, role, run, worktree_path, opts)

        {:ok, %OsProcess{} = os_process} ->
          broadcast_changed(os_process.run)
          {:ok, os_process}

        {:error, %Run{} = failed} ->
          broadcast_changed(failed)
          {:error, :worktree_setup_failed}
      end
    else
      nil -> {:error, :invalid_state}
      {:error, reason} -> fail(run, reason)
    end
  end

  defp reload(%Run{id: id}), do: Run |> Repo.get(id) |> Repo.preload([:task, role: :backend])

  defp worktree(%Project{} = project, %Task{} = task) do
    case prepare_worktree(project, task) do
      {:ok, task, resolved} -> {:ok, task, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  # Two things can reach a run's queue at once - the human sending now and the
  # exit of the turn they interrupted - and only one of them can carry the text.
  # The loser finds the queue empty, and an agent spawned with no prompt is an
  # error the run then wears, so it stops here instead.
  defp send_message(%Task{}, %Role{}, %Run{pending_chat: queued}, _worktree_path, _opts) when queued in [nil, ""] do
    {:error, :nothing_queued}
  end

  defp send_message(%Task{} = task, %Role{} = role, %Run{} = run, worktree_path, _opts) do
    message = run.pending_chat

    # The turn before this one is history the moment another starts. Its error
    # and exit code go with it: left on the row they read as this turn's, and a
    # run still wearing an error is one that can never be latched done.
    {:ok, run} =
      run
      |> Run.changeset(%{
        pending_chat: nil,
        # A person stepping in is what lets CI send its failures back again.
        ci_failure_streak: 0,
        status: :running,
        error: nil,
        exit_code: nil,
        started_at: run.started_at || DateTime.utc_now()
      })
      |> Repo.update()

    broadcast_changed(run)

    {:ok, _task} = task |> Task.changeset(%{worktree_path: worktree_path}) |> Repo.update()

    argv =
      Tools.build_args(
        backend: role.backend,
        prompt: message,
        model: role.model,
        reasoning_effort: role.reasoning_effort || "high",
        read_only: false,
        system_prompt: role.system_prompt,
        conversation_id: run.conversation_id,
        work_dir: worktree_path
      )

    case Tools.start_os_process(run, argv) do
      {:ok, %OsProcess{} = os_process} ->
        {:ok, os_process}

      {:error, {:spawn_failed, reason, _run}} ->
        requeue(run, message)
        fail(run, {:spawn_failed, reason})

      {:error, :dispatch_disabled} ->
        requeue(run, message)
        {:error, :dispatch_disabled}
    end
  end

  # The message never reached an agent, so it goes back on the row as though it
  # had never left: still queued, still the human's to cancel or re-send.
  defp requeue(%Run{} = run, message) do
    run |> Run.changeset(%{pending_chat: message}) |> Repo.update!() |> broadcast_changed()
  end

  # The dispatch runs in the background, so whoever queued the message only learns
  # it went out, or came back, from the run's topic.
  defp broadcast_changed(%Run{id: id}) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{id}", {:run_changed, id})
  end

  defp fail(%Run{} = run, reason) do
    Pipeline.append_run_events(run.id, nil, ["[rail] That message was not delivered: #{inspect(reason)}"])
    {:error, reason}
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
