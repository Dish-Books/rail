defmodule Rail.Runs.FollowerSupervisor do
  @moduledoc """
  DynamicSupervisor managing live Follower GenServers.
  """
  use DynamicSupervisor

  alias Rail.Runs.Follower

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new Follower process for an active run.
  """
  def start_follower(opts) when is_list(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Follower, opts})
  end

  @doc """
  Terminates a follower child.
  """
  def stop_follower(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
