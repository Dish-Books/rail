defmodule Rail.Tools.Actions.ReconcileBrowserSessions do
  @moduledoc """
  Closes the tabs nothing needs any more, and reconnects to the ones a running
  pass is still using.

  The shared Chrome outlives Rail, so a tab outlives whatever opened it. That is
  the point - a deploy in the middle of a pass leaves the pass's page where it
  was - and it is also the leak: a task that moved on from QA or demo leaves a
  tab signed into its app, open until the machine restarts, unless something
  closes it. This is what closes it: a task out of both stages has its context
  closed and its row settled, whatever holds it.

  A task still in QA or demo keeps its tab. One with a run executing right now is
  reconnected to it, so the panel is watching again and the tab's problems are
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

  @driven_stages [:qa, :demo]

  @doc """
  Closes every live session whose task has left QA and demo, reconnects every
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
      task.stage not in @driven_stages ->
        :ok = Tools.stop_browser_session(task)
        [Repo.get!(BrowserSession, session.id)]

      driven?(task) or not running?(task) ->
        []

      true ->
        _reconnected = Tools.start_browser_session(task, [])
        []
    end
  end

  defp driven?(%Task{id: task_id}), do: Registry.lookup(BrowserRegistry, task_id) != []

  defp running?(%Task{id: task_id}) do
    Repo.exists?(from r in Run, where: r.task_id == ^task_id and r.status in [:starting, :running])
  end
end
