defmodule Rail.Tools.Utils.LaunchSandboxTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  @gib 1024 ** 3

  setup %{project: project} do
    test_pid = self()

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/info"} ->
          Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib})

        {"POST", "/containers/create"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:created, Jason.decode!(body)})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c0ffee"})

        {"POST", "/containers/c0ffee/start"} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    stub(Rail, :sandbox_runtime, fn -> :docker end)

    tmp_dir = Path.join(System.tmp_dir!(), "launch_sandbox_#{System.unique_integer([:positive])}")
    worktree_path = Path.join(tmp_dir, "worktree")
    File.mkdir_p!(worktree_path)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})
    {:ok, seeded} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, role} =
      Roles.update_role(system_scope(), seeded, %{backend_id: backend.id, reserved_cpus: 2, reserved_memory_gb: 4})

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_launch_#{System.unique_integer([:positive])}",
        identifier: "LCH-1",
        title: "Launch Issue",
        state: :backlog
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "launch-1",
          worktree_path: worktree_path,
          scratch_path: Path.join(tmp_dir, "scratch"),
          worktree_slot: 3
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :starting, started_at: DateTime.utc_now()})

    %{backend: backend, run: run, worktree_path: worktree_path}
  end

  test "runs the turn where it would run beside Rail, with what it needs and none of Rail's own", %{
    backend: backend,
    run: run,
    worktree_path: worktree_path
  } do
    reject(Tools, :spawn_os_process, 3)

    assert {:ok, %OsProcess{status: :running, runtime: :docker, container_id: "c0ffee", launch: nil}} =
             Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, %{"WorkingDir" => ^worktree_path, "Env" => env, "HostConfig" => host_config}}
    env = Map.new(env, &(&1 |> String.split("=", parts: 2) |> List.to_tuple()))
    config_dir = Backend.config_dir(backend)

    assert %{"NetworkMode" => "host", "Binds" => ["/srv/rail:/srv/rail"], "Init" => true} = host_config

    assert %{
             "CLAUDE_CONFIG_DIR" => ^config_dir,
             "RAIL_PORT_BASE" => "20300",
             "RAIL_WORKTREE_SLOT" => "3",
             "RAIL_MCP_TOKEN" => "" <> _token,
             "PATH" => "" <> _path
           } = env

    # The tool environment Rail runs agents with beside itself, which keeps mise's
    # data and leaves Rail's own settings out (see Rail.Tools.Utils.EnvTest).
    assert env["MISE_DATA_DIR"] == System.get_env("MISE_DATA_DIR")
    refute Enum.any?(["MIX_ENV", "DATABASE_URL", "SECRET_KEY_BASE"], &Map.has_key?(env, &1))

    # A turn's compiles may use every CPU the machine leaves idle, so Rail pins no
    # schedulers; only what its own environment carries, as under CI, passes through.
    assert env["ERL_FLAGS"] == System.get_env("ERL_FLAGS")
  end

  # ExUnit runs twice as many cases as the BEAM has schedulers, so CI's are held
  # to its reservation; a flag the project passes comes after, where it wins.
  test "a CI sandbox's BEAM runs as many schedulers as its role reserves", %{run: run} do
    assert {:ok, %OsProcess{kind: :ci}} =
             Tools.start_command_process(run, :ci, "mix test", env: %{"ERL_FLAGS" => "+sbwt none"})

    assert_received {:created, %{"Env" => env}}
    assert "ERL_FLAGS=+S 2:2 +sbwt none" in env
  end

  # The machine has 16 CPUs and keeps 3 back, so the other 13 are the sandbox's
  # to use while idle; its reservation is its weight when others want them too.
  test "weighs the sandbox's CPUs by its reservation up to what the machine can spare, and caps memory with no swap", %{
    run: run
  } do
    stub(Rail, :sandbox_headroom_cpus, fn -> 3 end)

    assert {:ok, %OsProcess{reserved_cpus: 2, reserved_memory_gb: 4}} = Tools.start_os_process(run, ["-p", "Build it."])

    four_gb = 4 * @gib

    assert_received {:created, %{"HostConfig" => host_config}}

    assert %{"CpuShares" => 2048, "NanoCpus" => 13_000_000_000, "Memory" => ^four_gb, "MemorySwap" => ^four_gb} =
             host_config
  end

  test "a sandbox Docker will not start fails the run with why, and leaves nothing behind", %{run: run} do
    test_pid = self()

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/info"} ->
          Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib})

        {"POST", "/containers/create"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c0ffee"})

        {"POST", "/containers/c0ffee/start"} ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "no such image"})

        {"DELETE", "/containers/c0ffee"} ->
          send(test_pid, :removed)
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:error, {:spawn_failed, {:docker_api_error, 500, _body}, %Run{status: :finished, error: error}}} =
             Tools.start_os_process(run, ["-p", "x"])

    assert error =~ "Could not start its sandbox: {:docker_api_error, 500"
    assert_received :removed
    assert [%OsProcess{status: :finished, ended_reason: :failed_to_start}] = Tools.list_os_processes(run_id: run.id)
  end

  test "a worktree that is not there fails before Docker is asked to make one", %{run: run, worktree_path: worktree_path} do
    File.rm_rf!(worktree_path)
    Req.Test.stub(Docker, fn conn -> Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib}) end)

    assert {:error, {:spawn_failed, {:bad_cwd, ^worktree_path}, _run}} = Tools.start_os_process(run, ["-p", "x"])
  end

  test "waits in line when Docker cannot say what the machine has free", %{run: run} do
    Req.Test.stub(Docker, &Req.Test.transport_error(&1, :econnrefused))

    assert {:ok, %OsProcess{status: :waiting_for_resources}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert [
             "[rail] Turn 1 needs 2 CPUs and 4 GB, and Rail could not read what this machine has free. " <>
               "It is 1st in line and starts on its own as soon as enough is free."
           ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
  end
end
