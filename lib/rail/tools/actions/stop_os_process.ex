defmodule Rail.Tools.Actions.StopOsProcess do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.AdmitSandboxes

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Tools.Follower
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Stops an OS process, and frees what it held for the next in line.

  One still waiting for its sandbox or for usage has nothing to kill, so it just
  leaves its wait, and never starts. The row records who asked, when a person did.
  """
  def stop_os_process(%Scope{} = scope, %OsProcess{} = os_process, opts \\ []) do
    now = DateTime.utc_now()
    opts = Keyword.put(opts, :stopped_by_id, scope.user && scope.user.id)

    # Conditional, since the row may have started between being read and this.
    {left_line, _rows} =
      Repo.update_all(
        from(p in OsProcess, where: p.id == ^os_process.id and p.status in [:waiting_for_resources, :waiting_for_usage]),
        set: [
          status: :finished,
          ended_reason: :stopped,
          ended_at: now,
          stopped_by_id: Keyword.get(opts, :stopped_by_id),
          launch: nil,
          updated_at: now
        ]
      )

    if left_line == 1 do
      _admitted = admit_sandboxes()
      {:ok, Repo.get!(OsProcess, os_process.id)}
    else
      Follower.stop_os_process(Repo.get!(OsProcess, os_process.id), opts)
    end
  end
end
