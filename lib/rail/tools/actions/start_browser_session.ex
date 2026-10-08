defmodule Rail.Tools.Actions.StartBrowserSession do
  @moduledoc """
  Gets the browser an agent named on a task, starting one if there is not one yet.

  Asking twice gets the same session rather than a second tab: the registry is
  keyed by task and name, so a pass that reconnects after a crash, or a second
  tool call arriving before the first has finished starting, both land on the tab
  that is already there. Another name is another context and another tab.

  A name whose last session ended without closing its tab - Rail restarted, the
  session crashed - gets that tab back: its row still names the context and the
  target, and the new session attaches to them. A pass that was signed in and
  half way through a form is still signed in and half way through it. Only a tab
  that is not there any more is replaced.

  The row is written here rather than by the session itself. A process cannot
  record its own unexpected death, and the row is what says which context is
  still somebody's.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.BrowserSession
  alias Rail.Tools.BrowserSupervisor
  alias Rail.Tools.Schemas.BrowserSession, as: Session

  @doc """
  Returns `{:ok, pid}` for the browser session `name` on `task`.

  `opts` are passed to the session: `:subscribe` for a process that should
  receive the browser's own events, and `:ready_timeout_ms` for how long a Chrome
  that had to be started gets to answer.
  """
  def start_browser_session(%Task{} = task, name, opts \\ []) when is_binary(name) do
    case Tools.get_browser_session(task, name) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> resume(task, name, live(task, name), opts)
    end
  end

  defp live(%Task{id: task_id}, name) do
    Repo.one(from s in Session, where: s.task_id == ^task_id and s.name == ^name and s.status != :finished)
  end

  defp resume(%Task{} = task, name, %Session{browser_context_id: context, target_id: target} = session, opts)
       when is_binary(context) and is_binary(target) do
    resume = %{browser_context_id: context, target_id: target, account: session.account}

    case start(task, session, [{:resume, resume} | opts]) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:browser_unavailable, :tab_gone}} ->
        settle(session, :tab_gone)
        launch(task, name, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A row that never got as far as a tab stands for nothing, and only one live row
  # is allowed per name.
  defp resume(%Task{} = task, name, %Session{} = session, opts) do
    settle(session, :no_tab)
    launch(task, name, opts)
  end

  defp resume(%Task{} = task, name, nil, opts), do: launch(task, name, opts)

  defp launch(%Task{} = task, name, opts) do
    {:ok, session} =
      %Session{}
      |> Session.changeset(%{task_id: task.id, name: name, status: :starting, started_at: DateTime.utc_now()})
      |> Repo.insert()

    case start(task, session, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, settle(session, reason)}
    end
  end

  defp start(%Task{} = task, %Session{} = session, opts) do
    child = {BrowserSession, [{:task, task}, {:name, session.name}, {:session_id, session.id} | opts]}

    case DynamicSupervisor.start_child(BrowserSupervisor, child) do
      {:ok, pid} -> {:ok, record(session, pid)}
      # coveralls-ignore-start (two callers that both looked and both found
      # nothing, which is a window a test cannot stand inside)
      {:error, {:already_started, pid}} -> {:ok, pid}
      # coveralls-ignore-stop
      {:error, reason} -> {:error, reason}
    end
  end

  defp record(%Session{} = session, pid) do
    {:ok, _running} =
      session
      |> Session.changeset(Map.put(BrowserSession.details(pid), :status, :running))
      |> Repo.update()

    pid
  end

  # The browser never came up, or the tab the row pointed at is gone. Either way
  # this row stands for nothing that is open, and a live row nobody settles is
  # what stops the task ever getting a browser again.
  defp settle(%Session{} = session, outcome) do
    {:ok, _finished} =
      session
      |> Session.changeset(%{status: :finished, finished_at: DateTime.utc_now()})
      |> Repo.update()

    outcome
  end
end
