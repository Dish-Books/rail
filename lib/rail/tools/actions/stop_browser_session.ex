defmodule Rail.Tools.Actions.StopBrowserSession do
  @moduledoc """
  Closes every tab a task was being driven in, and the contexts they lived in.

  The shared Chrome stays up for everybody else; what goes is each of this task's
  contexts, whatever its name, and everything signed into it. A tab still open that nothing
  is connected to - Rail restarted since it was opened - is closed over a
  connection of its own, because a context nobody closes is a tab left open in a
  Chrome that never exits. A Chrome that is down has no tabs to close, and is not
  started to be told so.

  Stopping one that was never started is fine and does nothing: the caller is
  saying there should be no browser for this task, which is already true.
  """

  import Ecto.Query
  import Rail.Tools.Utils.EnsureBrowserHost

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Browser
  alias Rail.Tools.Schemas.BrowserSession

  @doc """
  Stops each of `task`'s browser sessions, closing its tab and context.
  """
  def stop_browser_session(%Task{id: task_id} = task) do
    live = Repo.all(from s in BrowserSession, where: s.task_id == ^task_id and s.status != :finished)

    for %BrowserSession{} = session <- live do
      case Tools.get_browser_session(task, session.name) do
        pid when is_pid(pid) -> :ok = GenServer.stop(pid, :normal, 10_000)
        nil -> close(session)
      end
    end

    {_settled, _returning} =
      BrowserSession
      |> where([s], s.task_id == ^task_id and s.status != :finished)
      |> Repo.update_all(set: [status: :finished, finished_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])

    :ok
  end

  defp close(%BrowserSession{browser_context_id: context}) when is_binary(context) do
    with {:ok, %{url: url}} <- ensure_browser_host(start: false),
         {:ok, connection} <- Browser.start_link(url: url) do
      _disposed = Browser.call(connection, "Target.disposeBrowserContext", %{browserContextId: context})
      GenServer.stop(connection, :normal, 1_000)
    end
  end

  defp close(%BrowserSession{}), do: :ok
end
