defmodule Rail.Pipeline.Utils.StopLiveProcess do
  @moduledoc """
  Kills whatever OS processes are carrying a run, if any are: its agent's turn, and at Plan the worktree setup
  running beside it.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  @live [:waiting_for_resources, :waiting_for_usage, :starting, :running]

  @doc """
  Stops each of `run`'s live OS processes on behalf of `scope` and returns `:ok`, whether
  or not there was one.
  """
  def stop_live_process(%Scope{} = scope, %Run{} = run, opts \\ []) do
    for %OsProcess{} = os_process <- Tools.list_os_processes(run_id: run.id, status: @live) do
      Tools.stop_os_process(scope, os_process, opts)
    end

    :ok
  end
end
