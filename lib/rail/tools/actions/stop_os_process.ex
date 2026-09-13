defmodule Rail.Tools.Actions.StopOsProcess do
  @moduledoc false

  alias Rail.Tools.Follower
  alias Rail.Tools.Schemas.OsProcess

  @doc """
  Terminates an active agent execution.
  """
  def stop_os_process(%OsProcess{} = os_process, opts \\ []) do
    Follower.stop_os_process(os_process, opts)
  end
end
