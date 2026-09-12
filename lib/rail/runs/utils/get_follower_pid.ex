defmodule Rail.Runs.Utils.GetFollowerPid do
  @moduledoc false

  alias Rail.Runs.FollowerRegistry

  @doc """
  Looks up the Follower GenServer PID for a given os process ID if running.
  """
  def get_follower_pid(os_process_id) do
    case Registry.lookup(FollowerRegistry, os_process_id) do
      [{pid, _value}] -> pid
      _other -> nil
    end
  end
end
