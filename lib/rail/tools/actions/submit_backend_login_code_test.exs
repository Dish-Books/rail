defmodule Rail.Tools.Actions.SubmitBackendLoginCodeTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  # The sign-in is a real child, driven through a CLI that behaves like
  # `claude auth login` does without a terminal.
  @moduletag :real_spawn

  setup do
    dir = Path.join(System.tmp_dir!(), "submit_backend_login_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    cli = Path.join(dir, "claude")

    File.write!(cli, """
    #!/bin/sh
    echo "visit: https://claude.com/cai/oauth/authorize?code=true&state=abc"
    printf 'Paste code here if prompted > '
    read code
    case "$code" in
      good-code) echo "$code" > "$CLAUDE_CONFIG_DIR/signed_in"; echo "Login successful."; exit 0 ;;
      hang) sleep 30 ;;
      *) echo "Invalid code"; exit 1 ;;
    esac
    """)

    File.chmod!(cli, 0o755)

    backend = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: cli}))

    %{backend: backend, dir: dir, scope: system_scope()}
  end

  test "signs the backend in with the code from the sign-in page", %{backend: backend, scope: scope} do
    assert {:ok, %{session: session}} = Tools.start_backend_login(scope, backend)
    ref = Process.monitor(session)

    assert :ok = Tools.submit_backend_login_code(scope, session, "  good-code \n")
    assert File.read!(Path.join(Backend.config_dir(backend), "signed_in")) == "good-code\n"
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}

    # The session is gone with its CLI, so there is nothing left to hand a code to.
    assert {:error, :login_exited} = Tools.submit_backend_login_code(scope, session, "good-code")
  end

  test "reports what the CLI said about a code it rejected", %{backend: backend, scope: scope} do
    assert {:ok, %{session: session}} = Tools.start_backend_login(scope, backend)
    assert {:error, "Invalid code"} = Tools.submit_backend_login_code(scope, session, "bad-code")
  end

  test "reports a sign-in that expires while the CLI is still working on the code", %{
    backend: backend,
    scope: scope
  } do
    assert {:ok, %{session: session}} = Tools.start_backend_login(scope, backend)

    submit = Task.async(fn -> Tools.submit_backend_login_code(scope, session, "hang") end)

    Enum.find(1..200, fn _attempt ->
      match?(%{waiting: {:code, _from}}, :sys.get_state(session)) || Process.sleep(10)
    end)

    send(session, :expire)
    assert {:error, :expired} = Task.await(submit)
  end

  test "reports a CLI that exited before the code arrived", %{backend: backend, dir: dir, scope: scope} do
    impatient = Path.join(dir, "impatient")

    File.write!(
      impatient,
      "#!/bin/sh\necho 'visit: https://claude.com/cai/oauth/authorize?x=1'\necho 'gave up'\nexit 3\n"
    )

    File.chmod!(impatient, 0o755)

    assert {:ok, %{session: session}} = Tools.start_backend_login(scope, %{backend | executable_path: impatient})

    # Nobody is waiting on the session, so its owner is told instead.
    assert_receive {:backend_login_exited, ^session, {:error, "gave up"}}, 5_000
    assert {:error, :login_exited} = Tools.submit_backend_login_code(scope, session, "good-code")
  end

  test "tells the owner when the CLI signs in without being handed a code", %{
    backend: backend,
    dir: dir,
    scope: scope
  } do
    # The browser the CLI opened handed the code straight back to it.
    finished = Path.join(dir, "finished")
    File.write!(finished, "#!/bin/sh\necho 'visit: https://claude.com/cai/oauth/authorize?x=1'\nsleep 0.2\nexit 0\n")
    File.chmod!(finished, 0o755)

    assert {:ok, %{session: session}} = Tools.start_backend_login(scope, %{backend | executable_path: finished})
    assert_receive {:backend_login_exited, ^session, :ok}, 5_000
  end
end
