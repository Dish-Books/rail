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
  # A process can be followed already: the reconciler may have found it between the
  # spawn recording its pid and asking for a Follower. That Follower is the one,
  # and it gets the port.
  def start_follower(%OsProcess{} = os_process, opts \\ []) when is_list(opts) do
    case DynamicSupervisor.start_child(__MODULE__, {Follower, {os_process, opts}}) do
      {:ok, follower_pid} ->
        {:ok, connect(follower_pid, opts)}

      {:error, {:already_started, follower_pid}} ->
        {:ok, connect(follower_pid, opts)}

      # coveralls-ignore-start (a Follower that refuses to start, which nothing
      # in its own init can bring about)
      {:error, reason} ->
        {:error, reason}
        # coveralls-ignore-stop
    end
  end

  @doc """
  Terminates a follower child.
  """
  def stop_follower(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  defp connect(follower_pid, opts) do
    case Keyword.get(opts, :port) do
      port when is_port(port) -> Tools.connect_port(port, follower_pid)
      _none -> :ok
    end

    follower_pid
  end
end
