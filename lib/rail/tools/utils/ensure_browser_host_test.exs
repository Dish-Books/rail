defmodule Rail.Tools.Utils.EnsureBrowserHostTest do
  use Rail.DataCase, async: false

  import Rail.Tools.Utils.EnsureBrowserHost

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker

  # Each test gets a browser root of its own, so the Chrome the rest of the suite
  # shares is neither found nor disturbed here.
  setup do
    set_mimic_global()
    root = Path.join(System.tmp_dir!(), "rail-host-#{System.unique_integer([:positive])}")
    stub(Rail, :browser_root, fn -> root end)
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, profile: Path.join(root, "profile")}
  end

  # Chrome announces itself by writing its port and websocket path into the
  # profile, and a port that answers is a Chrome that is up.
  test "a Chrome that is already answering is used as it is", %{profile: profile} do
    {:ok, listening} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listening)
    File.mkdir_p!(profile)
    File.write!(Path.join(profile, "DevToolsActivePort"), "#{port}\n/devtools/browser/abc\n")
    reject(Tools, :spawn_os_process, 3)

    url = "ws://127.0.0.1:#{port}/devtools/browser/abc"

    assert {:ok, %{url: ^url, port: ^port}} = ensure_browser_host()
  end

  # An address left behind by a Chrome that has since died is not a Chrome.
  test "an address nobody answers on is a Chrome that is down", %{profile: profile} do
    {:ok, listening} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listening)
    :gen_tcp.close(listening)
    File.mkdir_p!(profile)
    File.write!(Path.join(profile, "DevToolsActivePort"), "#{port}\n/devtools/browser/abc\n")

    assert {:error, :down} = ensure_browser_host(start: false)
  end

  test "asking without starting says so when nothing is up" do
    reject(Tools, :spawn_os_process, 3)

    assert {:error, :down} = ensure_browser_host(start: false)
  end

  # Beside Rail it is a detached process, with a lock from a Chrome that did not
  # exit cleanly cleared first so the profile is not refused.
  test "starts Chrome beside Rail when nothing is up", %{profile: profile} do
    {:ok, listening} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(listening)
    File.mkdir_p!(profile)
    File.write!(Path.join(profile, "SingletonLock"), "")

    expect(Tools, :spawn_os_process, fn _executable, args, _opts ->
      refute File.exists?(Path.join(profile, "SingletonLock"))
      assert "--user-data-dir=#{profile}" in args
      assert "--headless=new" in args
      File.write!(Path.join(profile, "DevToolsActivePort"), "#{port}\n/devtools/browser/fresh\n")
      {:ok, nil, 4242}
    end)

    assert {:ok, %{url: "ws://127.0.0.1:" <> _rest, port: ^port}} = ensure_browser_host()
  end

  # Chrome's log is the only account of why it never answered.
  test "a Chrome that never answers says what it logged" do
    stub(Tools, :terminate_os_process, fn _os_pid, _opts -> :ok end)

    stub(Tools, :spawn_os_process, fn _executable, _args, opts ->
      File.write!(opts[:stdout_path], "starting\nNo usable sandbox!\n")
      {:ok, nil, System.unique_integer([:positive])}
    end)

    assert {:error, {:devtools_never_answered, "starting\nNo usable sandbox!"}} =
             ensure_browser_host(ready_timeout_ms: 200)
  end

  test "a Chrome that never answers or logs says the log is missing" do
    stub(Tools, :terminate_os_process, fn _os_pid, _opts -> :ok end)
    stub(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:ok, nil, System.unique_integer([:positive])} end)

    assert {:error, {:devtools_never_answered, "chrome.log unreadable: enoent"}} =
             ensure_browser_host(ready_timeout_ms: 200)
  end

  # Chrome now and then hangs before it listens, so a hung one is killed with its
  # children and started once more before this gives up.
  test "a Chrome that hangs on its way up is killed and started again" do
    test_pid = self()

    stub(Tools, :spawn_os_process, fn _executable, _args, _opts ->
      os_pid = System.unique_integer([:positive])
      send(test_pid, {:spawned, os_pid})
      {:ok, nil, os_pid}
    end)

    stub(Tools, :terminate_os_process, fn os_pid, opts -> send(test_pid, {:terminated, os_pid, opts}) && :ok end)

    assert {:error, {:devtools_never_answered, _log}} = ensure_browser_host(ready_timeout_ms: 200)

    assert_received {:spawned, first}
    assert_received {:terminated, ^first, [group: true]}
    assert_received {:spawned, second}
    assert_received {:terminated, ^second, [group: true]}
    refute_received {:spawned, _third}
  end

  test "a machine with no Chrome says so" do
    stub(File, :exists?, fn _path -> false end)

    assert {:error, :chrome_not_found} = ensure_browser_host()
  end

  describe "under Docker" do
    setup %{profile: profile} do
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      reject(Tools, :spawn_os_process, 3)

      {:ok, listening} = :gen_tcp.listen(0, [])
      {:ok, port} = :inet.port(listening)
      File.mkdir_p!(profile)

      # What Chrome does once the container is up.
      announce = fn -> File.write!(Path.join(profile, "DevToolsActivePort"), "#{port}\n/devtools/browser/boxed\n") end

      %{port: port, announce: announce}
    end

    # Its own container, outliving Rail: host networking so every sandbox reaches
    # it on localhost, restarted by Docker if Chrome dies, and held to what it
    # was given.
    test "a browser container that does not exist is created and started", %{port: port, announce: announce} do
      test_pid = self()

      Req.Test.stub(Docker, fn
        %{method: "GET", request_path: "/containers/rail-browser/json"} = conn ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such container"})

        %{method: "POST", request_path: "/containers/create"} = conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:created, conn.query_string, Jason.decode!(body)})
          Req.Test.json(conn, %{"Id" => "browser1"})

        %{method: "POST", request_path: "/containers/browser1/start"} = conn ->
          announce.()
          Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, %{port: ^port}} = ensure_browser_host()

      assert_received {:created, "name=rail-browser", body}
      assert %{"NetworkMode" => "host", "RestartPolicy" => %{"Name" => "unless-stopped"}} = body["HostConfig"]
      assert body["HostConfig"]["Memory"] == Rail.browser_memory_gb() * 1024 ** 3
      assert body["Image"] == Rail.sandbox_image()
      assert ["/bin/sh", "-c", _script, _profile, "--headless=new" | _flags] = body["Cmd"]
      # Not a sandbox, so the sweep of settled sandboxes never removes it.
      refute Map.has_key?(body["Labels"], "dev.railai.sandbox")
    end

    test "a browser container that stopped is started again", %{port: port, announce: announce} do
      Req.Test.stub(Docker, fn
        %{method: "GET", request_path: "/containers/rail-browser/json"} = conn ->
          Req.Test.json(conn, %{"Id" => "browser1", "State" => %{"Running" => false}})

        %{method: "POST", request_path: "/containers/browser1/start"} = conn ->
          announce.()
          Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, %{port: ^port}} = ensure_browser_host()
    end

    # Docker restarting a crashed Chrome is a container that is running and not
    # answering yet, which is a wait rather than another container.
    test "a running container not answering yet is waited for", %{port: port, announce: announce} do
      Req.Test.stub(Docker, fn %{method: "GET", request_path: "/containers/rail-browser/json"} = conn ->
        announce.()
        Req.Test.json(conn, %{"Id" => "browser1", "State" => %{"Running" => true}})
      end)

      assert {:ok, %{port: ^port}} = ensure_browser_host()
    end

    test "a Docker that cannot be reached says why" do
      Req.Test.stub(Docker, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = ensure_browser_host()
    end
  end
end
