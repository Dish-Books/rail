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

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Git
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

  defp execute(%Run{} = run, opts) do
    with %Run{task: %Task{} = task, role: %Role{} = role} = run <- reload(run),
         %Project{} = project <- Repo.get(Project, task.project_id),
         {:ok, worktree_path} <- worktree(project, task) do
      send_message(task, role, run, worktree_path, opts)
    else
      nil -> {:error, :invalid_state}
      {:error, reason} -> fail(run, reason)
    end
  end

  defp reload(%Run{id: id}), do: Run |> Repo.get(id) |> Repo.preload([:task, role: :backend])

  defp worktree(%Project{} = project, %Task{} = task) do
    case Git.get_or_create_worktree(project, task) do
      {:ok, resolved} -> {:ok, resolved}
      {:error, reason} -> {:error, {:worktree_failed, reason}}
    end
  end

  defp send_message(%Task{} = task, %Role{} = role, %Run{} = run, worktree_path, _opts) do
    message = run.pending_chat || ""

    {:ok, run} =
      run
      |> Run.changeset(%{pending_chat: nil, status: :running, started_at: run.started_at || DateTime.utc_now()})
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
