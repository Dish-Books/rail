defmodule Rail.Runs.Actions.StopOsProcess do
  @moduledoc false

  alias Rail.Runs.Follower
  alias Rail.Runs.Schemas.OsProcess

  @doc """
  Terminates an active agent execution.
  """
  def stop_os_process(%OsProcess{} = os_process, opts \\ []) do
    Follower.stop_os_process(os_process, opts)
  end
end
