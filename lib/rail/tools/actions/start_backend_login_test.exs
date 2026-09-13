defmodule Rail.Tools.Actions.StartBackendLoginTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.LoginSession
  alias Rail.Tools.Schemas.Backend

  # The sign-in is a real child, driven through a CLI that behaves like
  # `claude auth login` does without a terminal.
  @moduletag :real_spawn

  setup do
    dir = Path.join(System.tmp_dir!(), "start_backend_login_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    cli = Path.join(dir, "claude")

    File.write!(cli, """
    #!/bin/sh
    [ "$*" = "auth login --claudeai" ] || { echo "unexpected args: $*"; exit 2; }
    echo "$CLAUDE_CONFIG_DIR" > "$CLAUDE_CONFIG_DIR/started_in"
    echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=abc"
    printf 'Paste code here if prompted > '
    read code
    exit 1
    """)

    File.chmod!(cli, 0o755)

    backend = Repo.insert!(Backend.changeset(%Backend{}, %{name: :claude, executable_path: cli}))

    %{backend: backend, dir: dir, scope: system_scope()}
  end

  test "hands back the sign-in URL from a CLI signing in to the backend's own directory", %{
    backend: backend,
    scope: scope
  } do
    url = "https://claude.com/cai/oauth/authorize?code=true&state=abc"

    assert {:ok, %{session: session, url: ^url}} = Tools.start_backend_login(scope, backend)
    assert Process.alive?(session)

    # The URL is kept, so asking again does not wait on the CLI.
    assert {:ok, ^url} = LoginSession.await_url(session)

    config_dir = Backend.config_dir(backend)
    assert File.read!(Path.join(config_dir, "started_in")) == config_dir <> "\n"

    Tools.cancel_backend_login(scope, session)
  end

  test "ends the sign-in when the process that started it goes away", %{backend: backend, scope: scope} do
    test_pid = self()

    owner =
      spawn(fn ->
        send(test_pid, {:started, Tools.start_backend_login(scope, backend, self())})
        Process.sleep(:infinity)
      end)

    assert_receive {:started, {:ok, %{session: session}}}, 5_000
    ref = Process.monitor(session)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
  end

  test "ends a sign-in left unfinished once it expires", %{backend: backend, scope: scope} do
    assert {:ok, %{session: session}} = Tools.start_backend_login(scope, backend)
    ref = Process.monitor(session)

    send(session, :expire)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}, 5_000
  end

  test "reports why a CLI gave up before offering a URL", %{backend: backend, dir: dir, scope: scope} do
    quiet = Path.join(dir, "quiet")
    File.write!(quiet, "#!/bin/sh\nexit 4\n")
    File.chmod!(quiet, 0o755)

    assert {:error, "Sign-in exited with code 4"} =
             Tools.start_backend_login(scope, %{backend | executable_path: quiet})

    # One that finishes without a URL at all is reported by its last words.
    assert {:error, "auth login --claudeai"} =
             Tools.start_backend_login(scope, %{backend | executable_path: "/bin/echo"})
  end

  test "refuses a backend whose CLI cannot be run, or cannot be signed in this way", %{
    backend: backend,
    scope: scope
  } do
    assert {:error, {:spawn_failed, _reason}} =
             Tools.start_backend_login(scope, %{backend | executable_path: "/non/existent/claude"})

    assert {:error, :unsupported} = Tools.start_backend_login(scope, %{backend | name: :agy})
  end
end
