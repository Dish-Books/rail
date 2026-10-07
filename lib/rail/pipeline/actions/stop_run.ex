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

  import Rail.Pipeline.Utils.BroadcastPipelineChanged
  import Rail.Pipeline.Utils.StopLiveProcess
  import Rail.Pipeline.Utils.WithdrawPlanComments

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Stops `run` on behalf of `scope` and returns `{:ok, run, queued_text}`, where `queued_text` is the
  message that had not been delivered yet, or `nil`. Plan comments queued in it go back to unsent and their rounds
  out of that text, unless `resending: true` says the caller sends it straight back out.
  """
  def stop_run(%Scope{} = scope, %Run{} = run, opts \\ []) do
    run = Run |> Repo.get!(run.id) |> Repo.preload(:task)
    queued = run.pending_chat
    was_running = Run.running?(run)

    # Take the queue off the row before the kill, not after. Stopping the process
    # settles the run synchronously, and a settle that still saw a queued message
    # would send it out from under the caller - twice over, racing whoever sends
    # it next for the one copy of the text.
    {:ok, drained} = run |> Run.changeset(%{pending_chat: nil}) |> Repo.update()

    stop_live_process(scope, drained, opts)

    # A round of plan comments handed back goes back to the tray rather than the composer.
    queued =
      if is_binary(queued) and not Keyword.get(opts, :resending, false),
        do: withdraw_plan_comments(run.task, queued),
        else: queued

    {:ok, mark_stopped(%{drained | task: run.task}, was_running), queued}
  end

  defp mark_stopped(%Run{} = run, was_running) do
    if was_running, do: Pipeline.append_run_events(run.id, nil, ["[rail] Stopped by user."])

    {:ok, stopped} =
      Run
      |> Repo.get!(run.id)
      |> Run.changeset(%{status: :finished})
      |> Repo.update()

    # A run stopped in line, or while it waited for usage, never ran, so no settle
    # announces it: the Overview and the task page are both told here.
    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run.id}", {:run_changed, run.id})
    broadcast_pipeline_changed(%{stopped | task: run.task})
  end
end
