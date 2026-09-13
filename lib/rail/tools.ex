defmodule Rail.Tools do
  @moduledoc """
  Public context for the external CLI tools Rail drives: the backends it knows
  how to run, the accounts signed in to them, and the OS processes they run in.
  """

  use Rail.PermissionsDecorator

  alias Rail.Tools.Actions

  defdelegate run(executable, args, opts \\ []), to: Actions.Run
  defdelegate spawn_os_process(executable, args, opts \\ []), to: Actions.SpawnOsProcess
  defdelegate connect_port(port, owner), to: Actions.ConnectPort
  defdelegate os_process_alive?(pid), to: Actions.OsProcessAlive
  defdelegate terminate_os_process(pid, opts \\ []), to: Actions.TerminateOsProcess

  defdelegate list_backends(), to: Actions.ListBackends
  defdelegate get_backend(name), to: Actions.GetBackend
  defdelegate refresh_usage(), to: Actions.RefreshUsage

  @decorate can?(resource: :backends, action: :manage)
  defdelegate create_backend(scope, attrs), to: Actions.CreateBackend

  @decorate can?(resource: :backends, action: :manage)
  defdelegate update_backend(scope, backend, attrs), to: Actions.UpdateBackend
end
