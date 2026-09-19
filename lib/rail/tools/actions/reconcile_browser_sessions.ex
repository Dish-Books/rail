defmodule Rail.Tools.Actions.ReconcileBrowserSessions do
  @moduledoc """
  Settles the browser sessions that nothing is driving any more.

  A session cleans up after itself when it stops, and that covers almost
  everything. What it cannot cover is not stopping: the application going down, the
  process being killed outright, a crash between launching Chrome and recording
  it. Those leave a row that still says `running` and, often, a Chrome holding a
  core for as long as the machine is up.

  Left alone that is two problems rather than one. The browser is the visible one.
  The row is worse: only one live session is allowed per task, so a task whose
  last browser died badly can never be given another, and QA on it stops working
  with no sign of why.

  A session with a live process is left to it, alive or dead - it owns its own
  browser and will settle its own row. Only what nothing is holding is reaped
  here, which is what makes this safe to run every minute.
  """

  import Ecto.Query

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.BrowserRegistry
  alias Rail.Tools.Schemas.BrowserSession

  @doc """
  Reaps every browser session whose process is gone, and returns them.
  """
  def reconcile_browser_sessions(_opts \\ []) do
    BrowserSession
    |> where([s], s.status in [:starting, :running])
    |> order_by([s], asc: s.started_at)
    |> Repo.all()
    |> Enum.reject(&driven?/1)
    |> Enum.map(&reap/1)
  end

  defp driven?(%BrowserSession{task_id: task_id}) do
    Registry.lookup(BrowserRegistry, task_id) != []
  end

  defp reap(%BrowserSession{} = session) do
    if session.os_pid, do: Tools.terminate_os_process(session.os_pid, [])
    if session.profile_path, do: File.rm_rf(session.profile_path)

    {:ok, reaped} =
      session
      |> BrowserSession.changeset(%{status: :finished, finished_at: DateTime.utc_now()})
      |> Repo.update()

    reaped
  end
end
