defmodule Rail.Pipeline.Actions.StopRun do
  @moduledoc """
  Stops a run, and hands back anything the human had queued on it.

  This is the only way anything is stopped. A stop is not a failure and not a
  cancellation: the run keeps everything it has, `stage_outcome` stays
  `:in_progress`, and the next message picks up where the agent left off. That is
  what makes stopping and then re-sending a message the ordinary way to redirect
  an agent mid-thought.

  An undelivered message comes back rather than being discarded, so cancelling a
  queued message is the same gesture — the text lands in the composer, to edit,
  re-send or throw away.
  """

  import Rail.Pipeline.Utils.StopLiveProcess

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  @doc """
  Stops `run` and returns `{:ok, run, queued_text}`, where `queued_text` is the
  message that had not been delivered yet, or `nil`.
  """
  def stop_run(%Run{} = run, opts \\ []) do
    run = Run |> Repo.get!(run.id) |> Repo.preload(:task)
    queued = run.pending_chat
    was_running = Run.running?(run)

    # Read the queue before the kill: stopping the process settles the run
    # synchronously, and the settle would otherwise send this message out.
    stop_live_process(run, opts)

    run = clear_queue(run, was_running)
    task = unwind_rebase(run.task)

    {:ok, %{run | task: task}, queued}
  end

  defp clear_queue(%Run{} = run, was_running) do
    if was_running, do: Runs.append_run_event(run, "[rail] Stopped by user.")

    {:ok, stopped} =
      Run
      |> Repo.get!(run.id)
      |> Run.changeset(%{pending_chat: nil, status: :finished})
      |> Repo.update()

    %{stopped | task: run.task}
  end

  # A rebase is a detour the task is parked in, and the detour is over.
  defp unwind_rebase(%Task{is_rebasing: true} = task) do
    {:ok, task} = task |> Task.changeset(%{is_rebasing: false}) |> Repo.update()
    task
  end

  defp unwind_rebase(%Task{} = task), do: task
end
