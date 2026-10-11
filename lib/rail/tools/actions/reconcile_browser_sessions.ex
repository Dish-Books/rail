defmodule Rail.Tools.Actions.ReconcileBrowserSessions do
  @moduledoc """
  Closes the tabs nothing needs any more, and reconnects to the ones a running
  pass is still using.

  The shared Chrome outlives Rail, so a tab outlives whatever opened it. That is
  the point - a deploy in the middle of a pass leaves the pass's page where it
  was - and it is also the leak: every tab left open is memory one Chrome shares
  between every task, until it is killed for it and takes every pass's tabs with
  it. So a tab is kept only for a run that is still running. A task that left
  Review, one that was cleaned up whatever stage it stopped at, and one waiting
  on a human between rounds each have every named context closed and their rows
  settled, whatever holds them; the next round signs in again.

  A row whose context Chrome no longer has - Chrome restarted since - is settled
  as lost, so the agent that asks for it again is told so.

  What is left is a running pass's own. Each tab nothing is connected to is
  reconnected by its name, so the panel is watching again and the tab's problems
  are collected again without waiting for the agent's next call to Rail.

  `Rail.Tools.Boot` runs this as Rail boots and every minute after, which is safe:
  a tab that is already held by a session is left to it.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.BrowserSession

  @driven_stages [:review]

  @doc """
  Closes every live session no running run needs, settles every one Chrome has
  lost, reconnects the rest, and returns the sessions it closed or settled.
  """
  def reconcile_browser_sessions(_opts \\ []) do
    contexts = Tools.list_browser_contexts()

    BrowserSession
    |> where([s], s.status in [:starting, :running])
    |> order_by([s], asc: s.started_at)
    |> preload(:task)
    |> Repo.all()
    |> Enum.flat_map(&reconcile(&1, contexts))
  end

  defp reconcile(%BrowserSession{task: %Task{} = task} = session, contexts) do
    cond do
      not wanted?(task) ->
        :ok = Tools.stop_browser_session(task)
        [Repo.get!(BrowserSession, session.id)]

      lost?(session, contexts) ->
        [lose(session, Tools.get_browser_session(task, session.name))]

      is_pid(Tools.get_browser_session(task, session.name)) ->
        []

      true ->
        # Only the tab the row names: one that went since is said to the agent
        # when it next asks, not replaced with a blank one behind its back.
        _reconnected = Tools.start_browser_session(task, session.name, existing: true)
        []
    end
  end

  defp wanted?(%Task{stage: stage, cleaned_up_at: cleaned_up_at, id: task_id}) do
    stage in @driven_stages and is_nil(cleaned_up_at) and
      Repo.exists?(from r in Run, where: r.task_id == ^task_id and r.status in [:starting, :running])
  end

  # A row still starting has no context yet, and a Chrome that did not answer has lost nothing.
  defp lost?(%BrowserSession{browser_context_id: "" <> context}, {:ok, contexts}),
    do: not MapSet.member?(contexts, context)

  defp lost?(%BrowserSession{}, _contexts), do: false

  # The session watching a context that is gone has nothing to close: it is
  # shut down rather than stopped, and the row says what happened to the tab.
  defp lose(%BrowserSession{} = session, pid) do
    if is_pid(pid), do: :ok = GenServer.stop(pid, :shutdown, 10_000)

    session
    |> BrowserSession.changeset(%{status: :finished, ended_reason: :browser_gone, finished_at: DateTime.utc_now()})
    |> Repo.update!()
  end
end
