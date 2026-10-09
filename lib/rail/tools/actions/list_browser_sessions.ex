defmodule Rail.Tools.Actions.ListBrowserSessions do
  @moduledoc """
  The browsers a task's agents have open, each by the name its agent gave it and the account it is signed in
  as, so the page can offer every one of them to watch.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Tools.Schemas.BrowserSession

  @doc """
  Lists `task`'s live browser sessions, oldest first with the id breaking a tie.
  """
  def list_browser_sessions(%Task{id: task_id}) do
    Repo.all(
      from s in BrowserSession,
        where: s.task_id == ^task_id and s.status in [:starting, :running],
        order_by: [asc_nulls_last: s.started_at, asc: s.inserted_at, asc: s.id]
    )
  end
end
