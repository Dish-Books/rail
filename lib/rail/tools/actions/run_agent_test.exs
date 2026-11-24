defmodule Rail.Tools.Actions.RunAgentTest do
  # Dispatch is switched off application-wide in one test, so nothing may run beside it.
  use Rail.DataCase, async: false

  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Backend

  setup do
    dir = Path.join(System.tmp_dir!(), "run_agent_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    script = Path.join(dir, "agent")

    File.write!(script, ~S"""
    #!/bin/sh
    case "$1" in
      fail) echo "broke"; exit 3 ;;
      refused) echo '{"type":"result","is_error":true,"error":"authentication_failed","result":"Invalid bearer token"}'; exit 1 ;;
      hang) sleep 5 ;;
      *) echo "$CLAUDE_CONFIG_DIR|$RAIL_MCP_TOKEN|$(pwd)" ;;
    esac
    """)

    File.chmod!(script, 0o755)

    model = "claude-run-agent-#{System.unique_integer([:positive])}"
    role = %Role{name: "Triage", cli: :claude, model: model}

    # A signed-in account running the script, offering `offered`, its windows `{label, percent left, resets_at}`.
    account = fn offered, windows, attrs ->
      {:ok, backend} =
        Tools.create_backend(system_scope(), %{
          name: :claude,
          label: attrs[:label],
          executable_path: script,
          models: [%{id: offered}]
        })

      reported =
        for {label, left, at} <- windows do
          %{
            name: label,
            details: %{
              "windows" => [
                %{"label" => label, "remaining_percent" => left, "resets_at" => at && DateTime.to_iso8601(at)}
              ]
            }
          }
        end

      Repo.update!(Backend.usage_changeset(backend, %{name: :claude, status: attrs[:status] || :ready, usage: reported}))
    end

    %{account: account, backend: account.(model, [], %{}), dir: dir, role: role, script: script}
  end

  # No Docker request is stubbed here, so one made under the local runtime would fail the test.
  test "runs the agent in the directory given, with the caller's env over the account's", %{
    backend: backend,
    dir: dir,
    role: role
  } do
    config_dir = Backend.config_dir(backend)

    assert {:ok, output} = Tools.run_agent(role, [], env: %{"RAIL_MCP_TOKEN" => "tok"}, cd: dir, timeout: 5_000)
    # `pwd` prints the physical path, which on macOS puts /private ahead of $TMPDIR.
    {physical_dir, 0} = System.cmd("pwd", ["-P"], cd: dir, env: %{})
    assert String.trim(output) == "#{config_dir}|tok|#{String.trim(physical_dir)}"

    assert {:ok, overridden} =
             Tools.run_agent(role, [], env: %{"CLAUDE_CONFIG_DIR" => "mine"}, cd: dir, timeout: 5_000)

    assert overridden =~ "mine|"
  end

  test "a non-zero exit, or no agent to run, is an error", %{backend: backend, dir: dir, role: role} do
    assert {:error, {:exit, 3, "broke\n"}} = Tools.run_agent(role, ["fail"], cd: dir, timeout: 5_000)

    {:ok, _missing} = Tools.update_backend(system_scope(), backend, %{executable_path: Path.join(dir, "no-such-agent")})
    assert {:error, %ErlangError{original: :enoent}} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
  end

  test "runs nothing when the only account offering the model is signed out", %{backend: backend, dir: dir, role: role} do
    backend |> Backend.usage_changeset(%{name: :claude, status: :signed_out}) |> Repo.update!()
    reject(&Tools.run/3)

    assert {:error, :backend_signed_out} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
  end

  test "a sign-in Claude refuses signs the account out once, so nothing more is started on it", %{
    backend: backend,
    dir: dir,
    role: role
  } do
    assert {:error, {:exit, 1, output}} = Tools.run_agent(role, ["refused"], cd: dir, timeout: 5_000)
    assert Tools.agent_failure_reason(output) =~ "Invalid bearer token. Sign the backend in again"

    assert %Backend{status: :signed_out, session_lost_at: %DateTime{} = lost_at, unavailable_reason: reason} =
             Repo.get!(Backend, backend.id)

    assert reason =~ "Claude refused this backend's sign-in."

    # A pass that started before the refusal was recorded changes nothing when it is refused too.
    Backend |> Repo.get!(backend.id) |> Backend.usage_changeset(%{name: :claude, status: :ready}) |> Repo.update!()
    assert {:error, {:exit, 1, _output}} = Tools.run_agent(role, ["refused"], cd: dir, timeout: 5_000)
    assert %Backend{session_lost_at: ^lost_at} = Repo.get!(Backend, backend.id)
  end

  test "an agent still running at the timeout is stopped", %{dir: dir, role: role} do
    assert {:error, :timeout} = Tools.run_agent(role, ["hang"], cd: dir, timeout: 100)
  end

  test "runs on the account a new conversation would, skipping one used up", %{
    account: account,
    backend: backend,
    dir: dir,
    role: role
  } do
    Repo.delete!(backend)
    in_a_day = DateTime.shift(DateTime.utc_now(), day: 1)
    _used_up = account.(role.model, [{"Weekly", 0.0, in_a_day}], %{label: "work"})
    roomy = account.(role.model, [{"Weekly", 80.0, in_a_day}], %{label: "personal"})

    assert {:ok, output} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
    assert output =~ Backend.config_dir(roomy)
  end

  test "waits for the earliest reset when every account is used up, and runs nothing", %{
    account: account,
    backend: backend,
    dir: dir,
    role: role
  } do
    soon = DateTime.utc_now() |> DateTime.shift(hour: 2) |> DateTime.truncate(:second)
    later = DateTime.utc_now() |> DateTime.shift(day: 3) |> DateTime.truncate(:second)
    Repo.delete!(backend)
    _first = account.(role.model, [{"Weekly", 0.0, later}], %{})
    _second = account.(role.model, [{"Session", 0.0, soon}], %{})

    reject(&Tools.run/3)
    assert {:error, {:waiting_for_usage, ^soon}} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
  end

  test "an account used up with no reset reported is looked at again after the next usage refresh", %{
    account: account,
    backend: backend,
    dir: dir,
    role: role
  } do
    Repo.delete!(backend)
    _spent = account.(role.model, [{"Weekly", 0.0, nil}], %{})

    assert {:error, {:waiting_for_usage, at}} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
    assert_in_delta DateTime.diff(at, DateTime.utc_now()), 5 * 60, 5
  end

  test "names the model when no account that can run it offers it", %{account: account, dir: dir, role: role} do
    _unconfigured = account.("claude-elsewhere", [], %{status: :not_configured})

    assert {:error, "No signed-in account offers claude-elsewhere. " <> _how} =
             Tools.run_agent(%{role | model: "claude-elsewhere"}, [], cd: dir, timeout: 5_000)
  end

  test "runs nothing while dispatch is off", %{dir: dir, role: role} do
    previous = Application.get_env(:rail, :no_dispatch)
    Application.put_env(:rail, :no_dispatch, true)
    on_exit(fn -> Application.put_env(:rail, :no_dispatch, previous) end)

    assert {:error, :dispatch_disabled} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
  end

  describe "under Docker" do
    setup %{backend: backend, dir: dir} do
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      scratch = Path.join(dir, "scratch")
      checkout = Path.join(dir, "checkout")
      config_dir = Backend.config_dir(backend)
      Enum.each([scratch, checkout, config_dir], &File.mkdir_p!/1)
      on_exit(fn -> File.rm_rf(config_dir) end)

      %{checkout: checkout, config_dir: config_dir, scratch: scratch}
    end

    test "runs in a container of its own that mounts only the pass's folders and its account's login", %{
      checkout: checkout,
      config_dir: config_dir,
      dir: dir,
      role: role,
      scratch: scratch,
      script: script
    } do
      test_pid = self()
      {:ok, polls} = Agent.start_link(fn -> ["created", "running", "exited"] end)

      Req.Test.stub(Docker, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case {conn.method, conn.request_path} do
          {"POST", "/containers/create"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:created, conn.query_params["name"], Jason.decode!(body)})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c-pass"})

          {"POST", "/containers/c-pass/start"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"GET", "/containers/c-pass/json"} ->
            status = Agent.get_and_update(polls, fn [now | rest] -> {now, if(rest == [], do: [now], else: rest)} end)
            Req.Test.json(conn, %{"State" => %{"Status" => status, "ExitCode" => 0}})

          {"GET", "/containers/c-pass/logs"} ->
            send(test_pid, {:logs, conn.query_params})
            Plug.Conn.send_resp(conn, 200, <<1, 0, 0, 0, 3::32, "out", 2, 0, 0, 0, 4::32, "err\n">>)

          {"DELETE", "/containers/c-pass"} ->
            send(test_pid, {:removed, conn.query_string})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:ok, "outerr\n"} =
               Tools.run_agent(role, ["--print"],
                 env: %{"RAIL_MCP_TOKEN" => "tok"},
                 cd: dir,
                 mounts: [scratch],
                 read_only_mounts: [checkout],
                 timeout: 90_000
               )

      assert_received {:created, "rail-agent-pass_" <> _id,
                       %{
                         "Image" => "rail-sandbox:latest",
                         "Cmd" => ["timeout", "-k", "5", "90", ^script, "--print"],
                         "WorkingDir" => ^dir,
                         "User" => "1000:1000",
                         "Env" => env,
                         "Labels" => %{"dev.railai.agent" => "true"} = labels,
                         "HostConfig" => %{"NetworkMode" => "host", "Init" => true, "Binds" => binds} = host_config
                       }}

      assert Enum.sort(binds) ==
               Enum.sort([
                 "#{dir}:#{dir}",
                 "#{config_dir}:#{config_dir}",
                 "#{scratch}:#{scratch}",
                 "#{checkout}:#{checkout}:ro"
               ])

      refute Map.has_key?(labels, "dev.railai.sandbox")
      refute Map.has_key?(host_config, "PidMode")
      refute Enum.any?(binds, &(&1 =~ "docker.sock"))
      assert "RAIL_MCP_TOKEN=tok" in env
      assert "CLAUDE_CONFIG_DIR=#{config_dir}" in env
      assert_received {:logs, %{"stdout" => "true", "stderr" => "true"}}
      assert_received {:removed, "force=true"}
    end

    test "a folder the pass mounts read-only is not also mounted writable", %{
      checkout: checkout,
      role: role,
      scratch: scratch
    } do
      test_pid = self()

      Req.Test.stub(Docker, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/containers/create"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)
            send(test_pid, {:binds, Jason.decode!(body)["HostConfig"]["Binds"], Jason.decode!(body)["Cmd"]})
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c-pass"})

          {"GET", "/containers/c-pass/json"} ->
            Req.Test.json(conn, %{"State" => %{"Status" => "exited", "ExitCode" => 3}})

          {"GET", "/containers/c-pass/logs"} ->
            Plug.Conn.send_resp(conn, 200, <<1, 0, 0, 0, 6::32, "broke\n">>)

          {_post_or_delete, _start_or_remove} ->
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:error, {:exit, 3, "broke\n"}} =
               Tools.run_agent(role, ["fail"], cd: checkout, mounts: [scratch], read_only_mounts: [checkout])

      assert_received {:binds, binds, cmd}
      assert "#{checkout}:#{checkout}:ro" in binds
      refute "#{checkout}:#{checkout}" in binds
      # With no limit given there is nothing for the container to stop it at.
      refute "timeout" in cmd
    end

    test "a container still running at the timeout is stopped and removed", %{dir: dir, role: role} do
      test_pid = self()

      Req.Test.stub(Docker, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/containers/create"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c-pass"})

          {"POST", "/containers/c-pass/start"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"GET", "/containers/c-pass/json"} ->
            Req.Test.json(conn, %{"State" => %{"Status" => "running"}})

          {"DELETE", "/containers/c-pass"} ->
            send(test_pid, {:removed, conn.query_string})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:error, :timeout} = Tools.run_agent(role, ["hang"], cd: dir, timeout: 100)
      assert_received {:removed, "force=true"}
    end

    test "a wait that crashes on a reply Docker should not give still removes the container", %{dir: dir, role: role} do
      test_pid = self()

      Req.Test.stub(Docker, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/containers/create"} ->
            conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c-pass"})

          {"POST", "/containers/c-pass/start"} ->
            Plug.Conn.send_resp(conn, 204, "")

          {"GET", "/containers/c-pass/json"} ->
            Req.Test.json(conn, %{"State" => "nonsense"})

          {"DELETE", "/containers/c-pass"} ->
            send(test_pid, {:removed, conn.query_string})
            Plug.Conn.send_resp(conn, 204, "")
        end
      end)

      assert {:error, %CaseClauseError{}} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
      assert_received {:removed, "force=true"}
    end

    test "a container Docker loses or kills mid-pass is an error, and still removed", %{dir: dir, role: role} do
      test_pid = self()

      for {inspected, expected} <- [
            {%{"State" => %{"Status" => "dead"}}, {:container, "dead"}},
            {:missing, {:docker_api_error, 404, %{"message" => "No such container"}}}
          ] do
        Req.Test.stub(Docker, fn conn ->
          case {conn.method, conn.request_path, inspected} do
            {"POST", "/containers/create", _inspected} ->
              conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c-pass"})

            {"POST", "/containers/c-pass/start", _inspected} ->
              Plug.Conn.send_resp(conn, 204, "")

            {"GET", "/containers/c-pass/json", :missing} ->
              conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such container"})

            {"GET", "/containers/c-pass/json", state} ->
              Req.Test.json(conn, state)

            {"DELETE", "/containers/c-pass", _inspected} ->
              send(test_pid, :removed)
              Plug.Conn.send_resp(conn, 204, "")
          end
        end)

        assert {:error, ^expected} = Tools.run_agent(role, [], cd: dir, timeout: 5_000)
        assert_received :removed
      end
    end

    test "a mount that is not there fails before any container is made", %{dir: dir, role: role} do
      missing = Path.join(dir, "gone")
      test_pid = self()

      Req.Test.stub(Docker, fn conn ->
        send(test_pid, {:requested, conn.request_path})
        Plug.Conn.send_resp(conn, 500, "")
      end)

      assert {:error, {:bad_cwd, ^missing}} = Tools.run_agent(role, [], cd: dir, read_only_mounts: [missing])
      refute_received {:requested, _path}
    end

    test "a container Docker will not create is an error", %{dir: dir, role: role} do
      Req.Test.expect(Docker, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such image: rail-sandbox:latest"})
      end)

      assert {:error, {:docker_api_error, 404, %{"message" => "No such image: rail-sandbox:latest"}}} =
               Tools.run_agent(role, [], cd: dir, timeout: 5_000)
    end
  end
end
