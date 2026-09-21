defmodule Rail.Tools.Actions.StartBrowserSession do
  @moduledoc """
  Gets the browser a task is being driven in, starting one if there is not one yet.

  Asking twice gets the same session rather than a second Chrome: the registry is
  keyed by task, so a pass that reconnects after a crash, or a second tool call
  arriving before the first has finished starting, both land on the browser that
  is already there.

  The row is written here rather than by the session itself. A process cannot
  record its own unexpected death, and that record is exactly what tells a reaper
  which Chrome to kill - so what the session launched is written down by the thing
  that asked for it, and `Rail.Tools.reconcile_browser_sessions/1` settles
  whatever ends without being asked to.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.BrowserSupervisor
  alias Rail.Tools.Schemas.BrowserSession, as: Session

  @doc """
  Returns `{:ok, pid}` for `task`'s browser session.

  `opts` are passed to the session: `:headless` to watch it work, and
  `:subscribe` for a process that should receive the browser's own events.
  """
  def start_browser_session(%Task{} = task, opts \\ []) do
    case Tools.get_browser_session(task) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> launch(task, opts)
    end
  end

  defp launch(%Task{} = task, opts) do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{
        task_id: task.id,
        status: :starting,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    child = {BrowserSession, [{:task, task}, {:session_id, session.id} | opts]}

    case DynamicSupervisor.start_child(BrowserSupervisor, child) do
      {:ok, pid} -> {:ok, record(session, pid)}
      # coveralls-ignore-start (two callers that both looked and both found
      # nothing, which is a window a test cannot stand inside)
      {:error, {:already_started, pid}} -> {:ok, settle(session, pid)}
      # coveralls-ignore-stop
      {:error, reason} -> {:error, settle(session, reason)}
    end
  end

  defp record(%Session{} = session, pid) do
    {:ok, _running} =
      session
      |> Session.changeset(Map.put(BrowserSession.details(pid), :status, :running))
      |> Repo.update()

    pid
  end

  # Two sessions raced, or the browser never came up. Either way this row stands
  # for nothing that is running, and a live row nobody settles is what stops the
  # task ever getting a browser again.
  defp settle(%Session{} = session, outcome) do
    {:ok, _finished} =
      session
      |> Session.changeset(%{status: :finished, finished_at: DateTime.utc_now()})
      |> Repo.update()

    outcome
  end
end
