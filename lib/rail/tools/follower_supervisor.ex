defmodule Rail.Tools.FollowerSupervisor do
  @moduledoc """
  DynamicSupervisor managing live Follower GenServers.
  """
  use DynamicSupervisor

  alias Rail.Tools
  alias Rail.Tools.Follower
  alias Rail.Tools.Schemas.OsProcess

  def start_link(init_arg \\ []) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new Follower process for `os_process`.

  The row says everything about what to follow -- its run, its stream, its OS pid
  and the backend whose stream format it speaks -- so it must arrive with `run`
  preloaded down to `role: :backend`, and `opts` carries only what the row cannot:
  the `:port` of a freshly spawned child and the tick intervals.

  When `opts` carries the `:port`, the port is handed to the Follower before this
  returns, so the spawning process can exit without taking the child down.
  """
  def start_follower(%OsProcess{} = os_process, opts \\ []) when is_list(opts) do
    with {:ok, follower_pid} <- DynamicSupervisor.start_child(__MODULE__, {Follower, {os_process, opts}}) do
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
