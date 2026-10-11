defmodule Rail.Tools.Actions.ReconcileBrowserSessions do
  @moduledoc """
  Closes the tabs nothing needs any more, and reconnects to the ones a running
  pass is still using.

  The shared Chrome outlives Rail, so a tab outlives whatever opened it. That is
  the point - a deploy in the middle of a pass leaves the pass's page where it
  was - and it is also the leak: a task that moved on from Review leaves a
  tab signed into its app, open until the machine restarts, unless something
  closes it. This is what closes it: a task past Finalize with no run in flight has
  every named context closed and its rows settled, whatever holds them.

  A task at Review or Finalize keeps its tabs, between rounds as well, and so does any task while a run is in
  flight, so a comment that resumes the lead after the merge keeps its browser until the turn ends. Each one a running run is driving is
  reconnected by its name, so the panel is watching again and the tab's problems are
  collected again without waiting for the agent's next call to Rail; one waiting
  on a human is left for its next pass to attach to.

  Safe to run every minute: a tab that is already held by a session is left to
  it.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.BrowserRegistry
  alias Rail.Tools.Schemas.BrowserSession

  @driven_stages [:review, :finalize]

  @doc """
  Closes every live session whose task is past Finalize with nothing in flight, reconnects every
  one a running pass is using, and returns the sessions it closed.

  """
  def reconcile_browser_sessions(_opts \\ []) do
    BrowserSession
    |> where([s], s.status in [:starting, :running])
    |> order_by([s], asc: s.started_at)
    |> preload(:task)
    |> Repo.all()
    |> Enum.flat_map(&reconcile/1)
  end

  defp reconcile(%BrowserSession{task: %Task{} = task} = session) do
    cond do
      task.stage not in @driven_stages and not in_flight?(task) ->
        :ok = Tools.stop_browser_session(task)
        [Repo.get!(BrowserSession, session.id)]

      driven?(session) or not running?(task) ->
        []

      true ->
        _reconnected = Tools.start_browser_session(task, session.name, [])
        []
    end
  end

  defp driven?(%BrowserSession{task_id: task_id, name: name}), do: Registry.lookup(BrowserRegistry, {task_id, name}) != []

  defp in_flight?(%Task{id: task_id}) do
    Repo.exists?(
      from r in Run,
        where: r.task_id == ^task_id and r.status in [:starting, :running, :waiting_for_resources, :waiting_for_usage]
    )
  end

  defp running?(%Task{id: task_id}) do
    Repo.exists?(from r in Run, where: r.task_id == ^task_id and r.status in [:starting, :running])
  end
end
