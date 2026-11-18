defmodule Rail.Pipeline.Utils.FailPlanWithoutApp do
  @moduledoc """
  Fails a Plan run whose browser could not start on the running app.

  Plan draws its design options from the app as it renders, never from the code alone, so a worktree that could not
  be set up or a browser that could not open is the plan failing rather than something to design around. The failure
  is the run's error: a turn still working keeps it through a clean exit, since Plan's finish leaves an error it finds
  in place, so the step stays open for the message that carries on once the cause is fixed, and that message clears it.
  """

  import Rail.Pipeline.Utils.BroadcastPipelineChanged

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Records on `run` that its browser could not start, because of `why`, and returns the error it now wears.
  """
  def fail_plan_without_app(%Run{id: run_id}, why) when is_binary(why) do
    error =
      "#{String.trim_trailing(why)} Plan designs from the running app, never from the code alone, so the plan " <>
        "failed. Once that is fixed, send a message to carry on."

    run = Repo.get!(Run, run_id)
    {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()

    Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{run_id}", {:run_changed, run_id})
    broadcast_pipeline_changed(%{failed | task: Repo.get!(Task, run.task_id)})
    error
  end
end
