defmodule Rail.Tools.LoginSessionTest do
  # Serial, because the stub has to reach a session the supervisor starts, not this process.
  use Rail.DataCase, async: false

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @moduletag :real_spawn

  setup :set_mimic_global

  setup do
    dir = Path.join(System.tmp_dir!(), "login_session_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir}
  end

  test "a CLI gone before its process id is read still says why it gave up", %{dir: dir} do
    quiet = Path.join(dir, "quiet")
    File.write!(quiet, "#!/bin/sh\nexit 4\n")
    File.chmod!(quiet, 0o755)
    backend = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: quiet}))

    # What a loaded machine does: the CLI has exited and closed its port before it is asked.
    stub(Port, :info, fn _port, :os_pid -> nil end)

    assert {:error, "Sign-in exited with code 4"} = Tools.start_backend_login(system_scope(), backend)
  end
end
