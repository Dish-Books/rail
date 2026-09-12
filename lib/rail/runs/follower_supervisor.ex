defmodule Rail.Runs.FollowerSupervisor do
  @moduledoc """
  DynamicSupervisor managing live Follower GenServers.
  """
  use DynamicSupervisor

  alias Rail.Runs.Follower
  alias Rail.Tools

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new Follower process for an active run.

  When `opts` carries the `:port` of a freshly spawned child, the port is handed
  to the Follower before this returns, so the spawning process can exit without
  taking the child down.
  """
  def start_follower(opts) when is_list(opts) do
    with {:ok, follower_pid} <- DynamicSupervisor.start_child(__MODULE__, {Follower, opts}) do
      case Keyword.get(opts, :port) do
        port when is_port(port) -> Tools.connect_port(port, follower_pid)
        _none -> :ok
      end

      {:ok, follower_pid}
    end
  end

  @doc """
  Terminates a follower child.
  """
  def stop_follower(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
