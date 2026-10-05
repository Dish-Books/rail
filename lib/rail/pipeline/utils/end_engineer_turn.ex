defmodule Rail.Pipeline.Utils.EndEngineerTurn do
  @moduledoc """
  Stops the engineer's turn, which settles it with no finish, then acts on the task
  in the background: Rail cannot push, start CI or merge while the agent runs.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.DispatchMessage
  import Rail.Pipeline.Utils.QuestionQueue
  import Rail.Pipeline.Utils.StopLiveProcess

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope

  @doc """
  Stops `task`'s engineer turn, then runs `act`, which returns `:ok` or
  `{:error, text}` for the run; a message queued meanwhile goes out once idle.
  """
  def end_engineer_turn(%Task{} = task, act) when is_function(act, 0) do
    run = engineer_run(task)
    queued = run.pending_chat

    # Off the row before the stop, which settles the run and would send it.
    {:ok, drained} = run |> Run.changeset(%{pending_chat: nil}) |> Repo.update()
    # Handed over, not stopped: the agent ended its own turn, and Sandboxes says so.
    stop_live_process(Scope.for_system(), drained, ended_reason: :handed_over)
    {:ok, stopped} = Run |> Repo.get!(run.id) |> Run.changeset(%{status: :finished}) |> Repo.update()

    caller = self()

    {:ok, _pid} =
      Elixir.Task.Supervisor.start_child(Rail.TaskSupervisor, fn ->
        allow_sandbox(caller)
        act_and_settle(stopped, act, queued)
      end)

    :ok
  end

  defp act_and_settle(%Run{} = run, act, queued) do
    result = attempt(act)
    run = Run |> Repo.get!(run.id) |> Repo.preload([:task, role: :backend])

    settled =
      case result do
        :ok -> latch_done(run)
        {:error, text} when is_binary(text) -> fail(run, text)
      end

    broadcast_pipeline_changed(settled)
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{settled.id}", {:run_changed, settled.id})
    requeue(settled, queued)
  end

  # The agent that asked is already stopped, so a crash here is said on the run,
  # where the human sees it, and the queued message still goes back.
  defp attempt(act) do
    act.()
  rescue
    exception -> {:error, "Could not finish the engineer's turn: " <> Exception.message(exception)}
  end

  # Starting CI, or a turn to resolve a merge, moved the run on, and what that
  # concludes is still to come.
  defp latch_done(%Run{status: status} = run) when status in [:running, :waiting_for_resources], do: run
  defp latch_done(%Run{} = run), do: update(run, %{stage_outcome: :done, error: nil})

  # Said in the conversation too, since a queued message starting the next turn
  # takes the run's error with it.
  defp fail(%Run{} = run, text) do
    # One line, since a log line that wraps reads its tail as the agent's words.
    Pipeline.append_run_events(run.id, nil, ["[rail] " <> (text |> String.split() |> Enum.join(" "))])
    update(run, %{error: text})
  end

  defp requeue(%Run{}, nil), do: :ok

  defp requeue(%Run{} = run, queued) do
    held = update(run, %{pending_chat: queued})

    if held.status not in [:running, :waiting_for_resources] and pending_questions(held.task_id) == [] do
      dispatch_message(held)
    end

    :ok
  end

  defp engineer_run(%Task{} = task) do
    {:ok, %Role{id: role_id}} = Roles.get_role(project_id: task.project_id, stage: :engineer)
    Repo.get_by!(Run, task_id: task.id, role_id: role_id)
  end

  defp update(%Run{} = run, attrs) do
    {:ok, updated} = run |> Run.changeset(attrs) |> Repo.update()
    %{updated | task: run.task, role: run.role}
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
