defmodule Rail.Tools.Actions.StopBrowserSession do
  @moduledoc """
  Closes the browser a task was being driven in.

  The process kills Chrome and removes the profile; the row is settled here,
  because a process that has stopped cannot say so. Stopping one that was never
  started is fine and does nothing: the caller is saying there should be no
  browser for this task, which is already true.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.BrowserSession

  @doc """
  Stops `task`'s browser session, killing Chrome and removing its profile.
  """
  def stop_browser_session(%Task{} = task) do
    case Tools.get_browser_session(task) do
      pid when is_pid(pid) -> stop(task, pid)
      nil -> :ok
    end
  end

  defp stop(%Task{id: task_id}, pid) do
    :ok = GenServer.stop(pid, :normal, 10_000)

    {_settled, _returning} =
      BrowserSession
      |> where([s], s.task_id == ^task_id and s.status != :finished)
      |> Repo.update_all(set: [status: :finished, finished_at: DateTime.utc_now(), updated_at: DateTime.utc_now()])

    :ok
  end
end
