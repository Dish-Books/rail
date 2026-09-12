defmodule Rail.Runs.Actions.StopOsProcess do
  @moduledoc false

  alias Rail.Runs.Follower

  @doc """
  Terminates an active agent execution by os process, run, or task ID.
  """
  def stop_os_process(os_process_or_run_or_task_id, opts \\ []) do
    Follower.stop_os_process(os_process_or_run_or_task_id, opts)
  end
end
