defmodule Rail.Tools do
  @moduledoc """
  Public context for the external CLI tools Rail drives: the backends it knows
  how to run, the accounts signed in to them, the OS processes they run in, and
  the streams those processes write.
  """

  use Rail.PermissionsDecorator
  use Supervisor

  alias Rail.Tools.Actions

  @doc """
  Starts the processes this context owns: the registries followers and browser
  sessions name themselves in, the supervisors they run under, and the boot-time
  adoption pass.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Rail.Tools.FollowerRegistry},
      Rail.Tools.FollowerSupervisor,
      {DynamicSupervisor, name: Rail.Tools.LoginSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Rail.Tools.BrowserRegistry},
      {Registry, keys: :unique, name: Rail.Tools.RecorderRegistry},
      {DynamicSupervisor, name: Rail.Tools.BrowserSupervisor, strategy: :one_for_one},
      Rail.Tools.Boot
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defdelegate run(executable, args, opts \\ []), to: Actions.Run
  defdelegate run_agent(role, argv, opts), to: Actions.RunAgent
  defdelegate agent_failure_reason(output), to: Actions.AgentFailureReason
  defdelegate spawn_os_process(executable, args, opts \\ []), to: Actions.SpawnOsProcess
  defdelegate connect_port(port, owner), to: Actions.ConnectPort
  defdelegate os_process_alive?(pid), to: Actions.OsProcessAlive
  defdelegate terminate_os_process(pid, opts \\ []), to: Actions.TerminateOsProcess

  defdelegate start_browser_session(task, name, opts \\ []), to: Actions.StartBrowserSession
  defdelegate get_browser_session(task, name), to: Actions.GetBrowserSession
  defdelegate get_browser_frame(task, name), to: Actions.GetBrowserFrame
  defdelegate get_browser_url(task, name), to: Actions.GetBrowserUrl
  defdelegate stop_browser_session(task), to: Actions.StopBrowserSession
  defdelegate reconcile_browser_sessions(opts \\ []), to: Actions.ReconcileBrowserSessions

  defdelegate capture_browser_evidence(session, task, name, key \\ nil, browser \\ nil),
    to: Actions.CaptureBrowserEvidence

  defdelegate file_qa_evidence(task, path, name, key, browser \\ nil), to: Actions.FileQaEvidence
  defdelegate list_browser_sessions(task), to: Actions.ListBrowserSessions

  defdelegate start_browser_recording(task, name), to: Actions.StartBrowserRecording
  defdelegate get_browser_recording(task), to: Actions.GetBrowserRecording
  defdelegate stop_browser_recording(task), to: Actions.StopBrowserRecording
  defdelegate encode_recording(directory, marks \\ []), to: Actions.EncodeRecording

  defdelegate build_args(opts), to: Actions.BuildArgs
  defdelegate start_os_process(run, argv), to: Actions.StartOsProcess
  defdelegate start_after_usage_reset(os_process_id), to: Actions.StartAfterUsageReset
  defdelegate get_usage_wait(run), to: Actions.GetUsageWait
  defdelegate start_command_process(run, kind, command, opts \\ []), to: Actions.StartCommandProcess
  defdelegate run_in_sandbox(os_process, command, opts \\ []), to: Actions.RunInSandbox
  defdelegate stop_os_process(scope, os_process, opts \\ []), to: Actions.StopOsProcess
  defdelegate get_os_process(id), to: Actions.GetOsProcess
  defdelegate get_active_os_process(run), to: Actions.GetActiveOsProcess
  defdelegate list_os_processes(opts \\ []), to: Actions.ListOsProcesses
  defdelegate get_sandbox_capacity(), to: Actions.GetSandboxCapacity
  defdelegate get_queue_position(run), to: Actions.GetQueuePosition
  defdelegate list_sandbox_usage(), to: Actions.ListSandboxUsage
  defdelegate ensure_toolchain(project), to: Actions.EnsureToolchain
  defdelegate install_toolchain(install_id), to: Actions.InstallToolchain
  defdelegate list_toolchain_installs(), to: Actions.ListToolchainInstalls
  defdelegate retry_toolchain_install(scope, install), to: Actions.RetryToolchainInstall
  defdelegate parse_stream(cli, lines, opts \\ []), to: Actions.ParseStream
  defdelegate plain_text(text), to: Actions.PlainText

  defdelegate list_backends(), to: Actions.ListBackends
  defdelegate list_models(), to: Actions.ListModels
  defdelegate get_backend(name), to: Actions.GetBackend
  defdelegate refresh_usage(), to: Actions.RefreshUsage

  @decorate can?(resource: :backends, action: :manage)
  defdelegate create_backend(scope, attrs), to: Actions.CreateBackend

  @decorate can?(resource: :backends, action: :manage)
  defdelegate update_backend(scope, backend, attrs), to: Actions.UpdateBackend

  @decorate can?(resource: :backends, action: :manage)
  defdelegate start_backend_login(scope, backend, owner \\ self()), to: Actions.StartBackendLogin

  @decorate can?(resource: :backends, action: :manage)
  defdelegate submit_backend_login_code(scope, session, code), to: Actions.SubmitBackendLoginCode

  @decorate can?(resource: :backends, action: :manage)
  defdelegate cancel_backend_login(scope, session), to: Actions.CancelBackendLogin

  @decorate can?(resource: :backends, action: :manage)
  defdelegate logout_backend(scope, backend), to: Actions.LogoutBackend
end
