defmodule Rail.Tools.Utils.LaunchSandboxTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Sandbox

  @gib 1024 ** 3

  setup do
    # A role's prompt is read from the project's clone, which here is a plain folder rather than a repository.
    stub(Rail.Git, :read_default_branch_file, fn _project, path -> {:error, "fatal: path '#{path}' does not exist"} end)
    # An engineer turn that ends asks git whether it left uncommitted work; the worktree here is a plain directory.
    stub(Rail.Git, :worktree_dirty?, fn _worktree_path -> false end)

    test_pid = self()

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/info"} ->
          Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib, "Architecture" => "aarch64"})

        {"POST", "/volumes/create"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:volume, Jason.decode!(body)})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

        {"POST", "/containers/create"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:created, conn.query_string, Jason.decode!(body)})
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c0ffee"})

        {"PUT", "/containers/c0ffee/archive"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:archive, conn.query_string, body})
          Plug.Conn.send_resp(conn, 200, "")

        {"POST", "/containers/c0ffee/update"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:updated, Jason.decode!(body)})
          Req.Test.json(conn, %{})

        {"POST", "/containers/c0ffee/start"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/containers/c0ffee/json"} ->
          Req.Test.json(conn, %{"State" => %{"Running" => true}})

        {"POST", "/containers/c0ffee/stop"} ->
          send(test_pid, :stopped)
          Plug.Conn.send_resp(conn, 204, "")

        {"DELETE", "/containers/c0ffee"} ->
          send(test_pid, :removed)
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    stub(Rail, :sandbox_runtime, fn -> :docker end)
    stub(Rail.Git, :sync_checkout, fn _task -> :ok end)

    # The project's clone, the task's folder and the toolchain each of its own, so a sandbox's mounts are this test's.
    tmp_dir = Path.join(System.tmp_dir!(), "launch_sandbox_#{System.unique_integer([:positive])}")
    clone_path = Path.join(tmp_dir, "clone")
    task_dir = Path.join(tmp_dir, "launch-1")
    worktree_path = Path.join(task_dir, "repo")
    scratch_path = Path.join(tmp_dir, "scratch")
    mise_dir = Path.join(tmp_dir, "mise")
    git_dir = Path.join(worktree_path, ".git")
    runner_dir = Path.join(tmp_dir, "runner")
    Enum.each([clone_path, scratch_path, mise_dir, runner_dir], &File.mkdir_p!/1)
    File.mkdir_p!(Path.join(runner_dir, "linux-arm64"))
    File.write!(Path.join([runner_dir, "linux-arm64", "rail-runner"]), "#!runner")
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    stub(Rail, :mise_data_dir, fn -> mise_dir end)
    stub(Rail, :runner_dir, fn -> runner_dir end)

    key = "LCH#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Launch",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: clone_path
      })

    model = "claude-launch-#{System.unique_integer([:positive])}"

    {:ok, backend} =
      Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true", models: [%{id: model}]})

    backend = Repo.update!(Backend.usage_changeset(backend, %{name: :claude, status: :ready}))
    config_dir = Backend.config_dir(backend)
    on_exit(fn -> File.rm_rf(config_dir) end)

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        stage: :engineer,
        cli: :claude,
        name: "Engineer",
        model: model,
        reserved_cpus: 2,
        system_prompt: "Build it."
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        identifier: "#{key}-1",
        title: "Launch Issue",
        state: :todo
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
          scratch_path: scratch_path,
          worktree_slot: 3
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :starting, started_at: DateTime.utc_now()})

    %{
      backend: backend,
      clone_path: clone_path,
      config_dir: config_dir,
      git_dir: git_dir,
      mise_dir: mise_dir,
      project: project,
      role: role,
      run: run,
      scratch_path: scratch_path,
      task_dir: task_dir,
      worktree_path: worktree_path
    }
  end

  test "runs the turn in its task's sandbox, which the runner dials Rail from, with what it needs and none of Rail's own",
       %{run: run, worktree_path: worktree_path} do
    reject(Tools, :spawn_os_process, 3)

    assert {:ok,
            %OsProcess{status: :running, runtime: :docker, container_id: "c0ffee", sandbox_id: "sbx_" <> _id} = os_process} =
             Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, "name=rail-sbx_" <> _name, %{"Env" => runner_env} = body}

    assert %{"Entrypoint" => ["/opt/rail/rail-runner"], "Cmd" => [], "User" => "0:0", "Image" => "rail-sandbox:latest"} =
             body

    assert "RAIL_SANDBOX_URL=ws://localhost:4000/sandbox/socket" in runner_env
    assert [_token] = for("RAIL_SANDBOX_TOKEN=" <> token <- runner_env, do: token)

    # The runner starts the turn once its Follower asks, from what the row keeps until then.
    # The prompt goes on stdin, as it does beside Rail.
    %{
      "argv" => ["/usr/bin/true" | _args],
      "env" => env,
      "cwd" => ^worktree_path,
      "stderr" => "separate",
      "stdin" => stdin
    } =
      Jason.decode!(Repo.reload!(os_process).launch)

    assert Base.decode64!(stdin) =~ "Build it."

    assert %{
             "RAIL_PORT_BASE" => "20300",
             "RAIL_WORKTREE_SLOT" => "3",
             "RAIL_MCP_TOKEN" => "" <> _token,
             "PATH" => "" <> _path
           } = env

    refute Map.has_key?(env, "RAIL_CLONE_PATH")
    refute Enum.any?(["MIX_ENV", "DATABASE_URL", "SECRET_KEY_BASE"], &Map.has_key?(env, &1))
    assert env["ERL_FLAGS"] == System.get_env("ERL_FLAGS")
  end

  test "a task's sandbox keeps its checkout on a volume of its own, and mounts only its scratch folder", %{
    run: run,
    scratch_path: scratch_path,
    worktree_path: worktree_path
  } do
    assert {:ok, %OsProcess{kind: :agent, sandbox_id: sandbox_id}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:volume, %{"Name" => volume, "Labels" => %{"dev.railai.task-sandbox" => ^sandbox_id}}}
    assert_received {:created, _name, %{"HostConfig" => host_config}}
    assert host_config["Binds"] == ["#{scratch_path}:#{scratch_path}"]
    assert host_config["Mounts"] == [%{"Type" => "volume", "Source" => volume, "Target" => worktree_path}]
    refute Map.has_key?(host_config, "Tmpfs")

    assert %Sandbox{status: :starting, container_id: "c0ffee", token_hash: <<_hash::binary-32>>} =
             Repo.get!(Sandbox, sandbox_id)
  end

  test "an agent's Claude keeps no login: it reaches its account through the runner, with the checkout trusted", %{
    run: run,
    worktree_path: worktree_path
  } do
    assert {:ok, %OsProcess{kind: :agent} = os_process} = Tools.start_os_process(run, ["-p", "Build it."])

    assert %{"claude" => true, "env" => env, "files" => [config]} = Jason.decode!(Repo.reload!(os_process).launch)
    assert env["CLAUDE_CONFIG_DIR"] == "/tmp/rail-claude"
    assert env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1"
    refute Map.has_key?(env, "RAIL_MCP_URL")
    assert %{"path" => "/tmp/rail-claude/.claude.json", "mode" => 0o600, "data" => data} = config

    assert %{"projects" => %{^worktree_path => %{"hasTrustDialogAccepted" => true}}} =
             data |> Base.decode64!() |> Jason.decode!()
  end

  test "a turn that resumes a conversation finds it where its CLI looks, put back from the account's copy", %{
    backend: backend,
    run: run,
    worktree_path: worktree_path
  } do
    session_dir = Backend.session_dir(backend, worktree_path)
    File.mkdir_p!(session_dir)
    File.write!(Path.join(session_dir, "conv-1.jsonl"), ~s({"type":"user"}\n))

    {:ok, run} = Pipeline.update_run(run, %{conversation_id: "conv-1"})

    assert {:ok, %OsProcess{} = os_process} =
             Tools.start_os_process(run, ["-p", "Go on.", "--resume", "conv-1"])

    assert %{"files" => [_config, transcript]} = Jason.decode!(Repo.reload!(os_process).launch)
    assert transcript["path"] == Path.join(Backend.sandbox_session_dir(worktree_path), "conv-1.jsonl")
    assert Base.decode64!(transcript["data"]) == ~s({"type":"user"}\n)
  end

  test "the runner for the host's architecture is put in the container before it starts", %{run: run} do
    assert {:ok, %OsProcess{}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:archive, "path=%2F", tar}
    tmp = Path.join(System.tmp_dir!(), "runner_tar_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    :ok = :erl_tar.extract({:binary, tar}, cwd: String.to_charlist(tmp))
    assert File.read!(Path.join(tmp, "opt/rail/rail-runner")) == "#!runner"
    assert Bitwise.band(File.stat!(Path.join(tmp, "opt/rail/rail-runner")).mode, 0o777) == 0o755
  end

  test "a host with no runner for its architecture starts nothing, and says which file is missing", %{run: run} do
    stub(Rail, :runner_dir, fn -> "/nonexistent/runner" end)

    assert {:error, {:spawn_failed, "/nonexistent/runner/linux-arm64/rail-runner: no such file or directory", _run}} =
             Tools.start_os_process(run, ["-p", "x"])

    refute_received {:created, _name, _body}
  end

  test "setup and CI run in the sandbox the task already has, weighed by what they all reserve", %{run: run} do
    assert {:ok, %OsProcess{kind: :setup, sandbox_id: sandbox_id}} =
             Tools.start_command_process(run, :setup, "./setup.sh")

    assert_received {:created, _name, %{"HostConfig" => %{"CpuShares" => 2048}}}

    assert {:ok, %OsProcess{kind: :ci, sandbox_id: ^sandbox_id} = ci} =
             Tools.start_command_process(run, :ci, "mix test", reserved_cpus: 1)

    refute_received {:created, _name, _body}
    assert_received {:updated, %{"CpuShares" => 3072}}
    assert %{"stderr" => "merge", "argv" => ["/bin/sh", "-c", _script]} = Jason.decode!(Repo.reload!(ci).launch)
  end

  test "a command gets no way to Claude", %{run: run} do
    assert {:ok, %OsProcess{kind: :setup} = setup} = Tools.start_command_process(run, :setup, "./setup.sh")

    assert %{"claude" => false, "files" => [], "env" => env} = Jason.decode!(Repo.reload!(setup).launch)
    refute Map.has_key?(env, "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC")
  end

  test "a task from before sandboxes had disks gets a copy of its checkout on its first", %{
    git_dir: git_dir,
    run: run,
    worktree_path: worktree_path
  } do
    File.mkdir_p!(git_dir)
    test_pid = self()

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/info"} ->
          Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib, "Architecture" => "x86_64"})

        {"POST", "/volumes/create"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

        {"POST", "/containers/create"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(body)
          send(test_pid, {:created, body})
          id = if body["Cmd"] == ["cp", "-a", "/from/.", "/to/"], do: "seeder", else: "c0ffee"
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => id})

        {"GET", "/containers/seeder/json"} ->
          Req.Test.json(conn, %{"State" => %{"Status" => "exited", "ExitCode" => 0}})

        {"POST", "/containers/" <> _start} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"PUT", "/containers/c0ffee/archive"} ->
          Plug.Conn.send_resp(conn, 200, "")

        {"DELETE", "/containers/" <> id} ->
          send(test_pid, {:removed, id})
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/containers/c0ffee/json"} ->
          Req.Test.json(conn, %{"State" => %{"Running" => true}})
      end
    end)

    File.mkdir_p!(Path.join(Rail.runner_dir(), "linux-amd64"))
    File.write!(Path.join([Rail.runner_dir(), "linux-amd64", "rail-runner"]), "#!runner")

    assert {:ok, %OsProcess{status: :running}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, %{"HostConfig" => %{"Binds" => [seed_bind], "Mounts" => [%{"Target" => "/to"}]}}}
    assert seed_bind == "#{worktree_path}:/from:ro"
    assert_received {:removed, "seeder"}
    assert_received {:created, %{"Entrypoint" => ["/opt/rail/rail-runner"]}}
  end

  test "a copy of an old checkout that fails starts nothing, saying how it exited", %{git_dir: git_dir, run: run} do
    File.mkdir_p!(git_dir)

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/info"} -> Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib, "Architecture" => "aarch64"})
        {"POST", "/volumes/create"} -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})
        {"POST", "/containers/create"} -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "seeder"})
        {"POST", "/containers/seeder/start"} -> Plug.Conn.send_resp(conn, 204, "")
        {"GET", "/containers/seeder/json"} -> Req.Test.json(conn, %{"State" => %{"Status" => "exited", "ExitCode" => 1}})
        {"DELETE", "/containers/seeder"} -> Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:error, {:spawn_failed, "Copying the task's checkout onto its sandbox's disk exited with 1", _run}} =
             Tools.start_os_process(run, ["-p", "x"])
  end

  test "a copy of an old checkout is waited on while it runs, and one Docker loses starts nothing", %{
    git_dir: git_dir,
    run: run
  } do
    File.mkdir_p!(git_dir)
    {:ok, looked} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/info"} ->
          Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib, "Architecture" => "aarch64"})

        {"POST", "/volumes/create"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

        {"POST", "/containers/create"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "seeder"})

        {"POST", "/containers/seeder/start"} ->
          Plug.Conn.send_resp(conn, 204, "")

        {"GET", "/containers/seeder/json"} ->
          if Agent.get_and_update(looked, &{&1, &1 + 1}) == 0,
            do: Req.Test.json(conn, %{"State" => %{"Status" => "running"}}),
            else: conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "gone"})

        {"DELETE", "/containers/seeder"} ->
          Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:error, {:spawn_failed, {:docker_api_error, 404, _body}, _run}} = Tools.start_os_process(run, ["-p", "x"])
    assert Agent.get(looked, & &1) == 2
  end

  test "toolchains come from the host's volume, read-only, where one is set", %{mise_dir: mise_dir, run: run} do
    stub(Rail, :toolchain_volume, fn -> "rail-mise" end)

    assert {:ok, %OsProcess{}} = Tools.start_os_process(run, ["-p", "Build it."])
    assert_received {:created, _name, %{"HostConfig" => %{"Mounts" => [_checkout, toolchain]}}}
    assert toolchain == %{"Type" => "volume", "Source" => "rail-mise", "Target" => mise_dir, "ReadOnly" => true}
  end

  # ExUnit runs twice as many cases as the BEAM has schedulers, so CI's are held
  # to its reservation; a flag the project passes comes after, where it wins.
  test "a CI command's BEAM runs as many schedulers as it reserves, not its role", %{run: run} do
    assert {:ok, %OsProcess{kind: :ci, reserved_cpus: 4} = ci} =
             Tools.start_command_process(run, :ci, "mix test", env: %{"ERL_FLAGS" => "+sbwt none"}, reserved_cpus: 4)

    assert %{"env" => %{"ERL_FLAGS" => "+S 4:4 +sbwt none"}} = Jason.decode!(Repo.reload!(ci).launch)
  end

  # The machine has 16 CPUs, keeps 3 back and gives the shared browser 2, so the
  # other 11 are the sandbox's to use while idle; its reservation is its weight
  # when others want them too.
  test "weighs the sandbox's CPUs by its reservation up to what the machine can spare, and leaves its memory unlimited",
       %{run: run} do
    stub(Rail, :sandbox_headroom_cpus, fn -> 3 end)
    stub(Rail, :browser_cpus, fn -> 2 end)

    assert {:ok, %OsProcess{reserved_cpus: 2}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, _name, %{"HostConfig" => host_config}}
    assert %{"CpuShares" => 2048, "NanoCpus" => 11_000_000_000, "OomScoreAdj" => 500} = host_config
    refute Map.has_key?(host_config, "Memory")
  end

  test "weighs a sandbox that reserves part of a CPU by that part", %{run: run} do
    {:ok, _role} = Roles.update_role(system_scope(), Repo.preload(run, :role).role, %{reserved_cpus: 0.5})

    assert {:ok, %OsProcess{reserved_cpus: 0.5}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, _name, %{"HostConfig" => %{"CpuShares" => 512}}}
  end

  test "a sandbox Docker will not start fails the run with why, and leaves no container behind", %{run: run} do
    test_pid = self()

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/info"} ->
          Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib, "Architecture" => "arm64"})

        {"POST", "/volumes/create"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{})

        {"POST", "/containers/create"} ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c0ffee"})

        {"PUT", "/containers/c0ffee/archive"} ->
          Plug.Conn.send_resp(conn, 200, "")

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
    assert [%Sandbox{status: :stopped, container_id: nil}] = Repo.all(Sandbox)
  end

  test "an agent turn joins its task's busy sandbox whatever account it is on", %{run: run} do
    assert {:ok, %OsProcess{kind: :setup, sandbox_id: sandbox_id}} =
             Tools.start_command_process(run, :setup, "./setup.sh")

    assert_received {:created, _name, _body}

    assert {:ok, %OsProcess{kind: :agent, status: :running, sandbox_id: ^sandbox_id}} =
             Tools.start_os_process(run, ["-p", "Build it."])

    refute_received {:created, _name, _body}
  end

  test "a host running as many sandboxes as it may gives up an idle one's container for a new task's", %{
    project: project,
    run: run
  } do
    stub(Rail, :max_sandboxes, fn -> 1 end)

    issue =
      %Issue{}
      |> Issue.changeset(%{project_id: project.id, identifier: "#{project.key}-9", title: "Idle", state: :todo})
      |> Repo.insert!()

    other =
      %Task{}
      |> Task.changeset(
        %{issue_id: issue.id, stage: :engineer, worktree_name: "idle", worktree_path: "/w/idle", scratch_path: "/s/idle"},
        project.id
      )
      |> Repo.insert!()

    idle =
      Repo.insert!(%Sandbox{
        task_id: other.id,
        engine: :docker,
        image: "rail-sandbox:latest",
        volume: "rail-idle",
        status: :running,
        container_id: "c0ffee",
        started_at: DateTime.utc_now()
      })

    assert {:ok, %OsProcess{status: :running}} = Tools.start_os_process(run, ["-p", "Build it."])
    assert_received :stopped
    assert %Sandbox{status: :stopped, container_id: nil} = Repo.reload!(idle)
  end

  test "a host running as many busy sandboxes as it may keeps a new task's command waiting", %{
    project: project,
    role: role,
    run: run
  } do
    stub(Rail, :max_sandboxes, fn -> 1 end)

    issue =
      %Issue{}
      |> Issue.changeset(%{project_id: project.id, identifier: "#{project.key}-8", title: "Busy", state: :todo})
      |> Repo.insert!()

    other =
      %Task{}
      |> Task.changeset(
        %{issue_id: issue.id, stage: :engineer, worktree_name: "busy", worktree_path: "/w/busy", scratch_path: "/s/busy"},
        project.id
      )
      |> Repo.insert!()

    busy =
      Repo.insert!(%Sandbox{
        task_id: other.id,
        engine: :docker,
        image: "rail-sandbox:latest",
        volume: "rail-busy",
        status: :running,
        container_id: "b0ffee",
        started_at: DateTime.utc_now()
      })

    {:ok, other_run} =
      Pipeline.create_run(%{task_id: other.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    Repo.insert!(%OsProcess{
      run_id: other_run.id,
      task_id: other.id,
      sandbox_id: busy.id,
      stream_path: "/dev/null",
      status: :running,
      started_at: DateTime.utc_now()
    })

    assert {:ok, %OsProcess{status: :waiting_for_resources}} = Tools.start_command_process(run, :setup, "./setup.sh")
    refute_received {:created, _name, _body}
  end

  test "waits in line when Docker cannot say what the machine has free", %{run: run} do
    Req.Test.stub(Docker, &Req.Test.transport_error(&1, :econnrefused))

    assert {:ok, %OsProcess{status: :waiting_for_resources}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert [
             "[rail] Turn 1 needs 2 CPUs, and Rail could not read what this machine has free. " <>
               "It is 1st in line and starts on its own as soon as enough is free."
           ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
  end
end
