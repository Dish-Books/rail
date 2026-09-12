defmodule Rail.Tools do
  @moduledoc """
  Public context for running external CLI tools with login-shell PATH parity,
  and for spawning and signalling the OS processes they run in.
  """

  alias Rail.Tools.Actions

  defdelegate run(executable, args, opts \\ []), to: Actions.Run
  defdelegate resolve(executable), to: Actions.Resolve
  defdelegate env(extra \\ %{}), to: Actions.Env
  defdelegate spawn_os_process(executable, args, opts \\ []), to: Actions.SpawnRun
  defdelegate connect_port(port, owner), to: Actions.ConnectPort
  defdelegate os_process_alive?(pid), to: Actions.OsProcessAlive
  defdelegate terminate_os_process(pid, opts \\ []), to: Actions.TerminateOsProcess
end
