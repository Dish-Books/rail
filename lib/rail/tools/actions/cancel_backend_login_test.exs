defmodule Rail.Tools.Actions.CancelBackendLoginTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @moduletag :real_spawn

  test "stops the session and the CLI waiting for its code" do
    dir = Path.join(System.tmp_dir!(), "cancel_backend_login_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    cli = Path.join(dir, "claude")
    File.write!(cli, "#!/bin/sh\necho 'visit: https://claude.com/cai/oauth/authorize?x=1'\nsleep 30\n")
    File.chmod!(cli, 0o755)

    scope = system_scope()
    backend = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: cli}))

    assert {:ok, %{session: session}} = Tools.start_backend_login(scope, backend)
    %{os_pid: os_pid} = :sys.get_state(session)
    assert Tools.os_process_alive?(os_pid)

    assert :ok = Tools.cancel_backend_login(scope, session)
    refute Process.alive?(session)
    refute Tools.os_process_alive?(os_pid)
  end
end
