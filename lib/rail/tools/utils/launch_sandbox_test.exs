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

    # The project's clone, the task's folder and the toolchain each of its own, so a sandbox's mounts are this test's.
    tmp_dir = Path.join(System.tmp_dir!(), "launch_sandbox_#{System.unique_integer([:positive])}")
    clone_path = Path.join(tmp_dir, "clone")
    task_dir = Path.join(tmp_dir, "launch-1")
    worktree_path = Path.join(task_dir, "repo")
    scratch_path = Path.join(tmp_dir, "scratch")
    mise_dir = Path.join(tmp_dir, "mise")
    Enum.each([clone_path, worktree_path, scratch_path, mise_dir], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    stub(Rail, :mise_data_dir, fn -> mise_dir end)

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
      mise_dir: mise_dir,
      project: project,
      role: role,
      run: run,
      scratch_path: scratch_path,
      task_dir: task_dir,
      worktree_path: worktree_path
    }
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

    assert %{"NetworkMode" => "host", "Init" => true} = host_config

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

  test "an agent's turn mounts only its task's folders, its clone and toolchain read-only, and its account's login", %{
    backend: backend,
    clone_path: clone_path,
    config_dir: config_dir,
    mise_dir: mise_dir,
    run: run,
    scratch_path: scratch_path,
    task_dir: task_dir,
    worktree_path: worktree_path
  } do
    session_dir = Backend.session_dir(backend, worktree_path)

    assert {:ok, %OsProcess{kind: :agent, status: :running}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, %{"HostConfig" => %{"Binds" => binds, "Tmpfs" => tmpfs}}}
    locked = Enum.map(["settings.json", "settings.local.json", "CLAUDE.md"], &Path.join(config_dir, &1))

    assert Enum.sort(binds) ==
             Enum.sort(
               [
                 "#{task_dir}:#{task_dir}",
                 "#{scratch_path}:#{scratch_path}",
                 "#{clone_path}:#{clone_path}:ro",
                 "#{mise_dir}:#{mise_dir}:ro",
                 "#{config_dir}:#{config_dir}",
                 "#{session_dir}:#{session_dir}"
               ] ++ Enum.map(locked, &"#{&1}:#{&1}:ro")
             )

    hidden = [
      "projects",
      "sessions",
      "session-env",
      "shell-snapshots",
      "todos",
      "file-history",
      "backups",
      "agents",
      "commands",
      "skills",
      "plugins",
      "output-styles",
      "rules"
    ]

    # The account's earlier conversations are covered, and only this turn's own is bound back inside the cover.
    assert tmpfs == Map.new(hidden, &{Path.join(config_dir, &1), "uid=1000,gid=1000,mode=0700"})
    assert Path.dirname(session_dir) == Path.join(config_dir, "projects")
    # Made as Rail's user, so Docker does not make it as root.
    assert File.dir?(session_dir)
  end

  test "setup and CI on a task mount the same folders as its agent, and no account's login", %{
    clone_path: clone_path,
    mise_dir: mise_dir,
    run: run,
    scratch_path: scratch_path,
    task_dir: task_dir
  } do
    expected =
      Enum.sort([
        "#{task_dir}:#{task_dir}",
        "#{scratch_path}:#{scratch_path}",
        "#{clone_path}:#{clone_path}:ro",
        "#{mise_dir}:#{mise_dir}:ro"
      ])

    assert {:ok, %OsProcess{kind: :setup}} = Tools.start_command_process(run, :setup, "./setup.sh")
    assert_received {:created, %{"HostConfig" => %{"Binds" => setup_binds, "Tmpfs" => setup_tmpfs}}}
    assert Enum.sort(setup_binds) == expected
    assert setup_tmpfs == %{}

    assert {:ok, %OsProcess{kind: :ci}} = Tools.start_command_process(run, :ci, "mix test")
    assert_received {:created, %{"HostConfig" => %{"Binds" => ci_binds, "Tmpfs" => ci_tmpfs}}}
    assert Enum.sort(ci_binds) == expected
    assert ci_tmpfs == %{}
  end

  test "old tasks' worktrees and triage checkouts in the clone are covered", %{clone_path: clone_path, run: run} do
    worktrees = Path.join(clone_path, ".worktrees")
    File.mkdir_p!(Path.join(worktrees, "another-task"))

    assert {:ok, %OsProcess{kind: :ci}} = Tools.start_command_process(run, :ci, "mix test")

    assert_received {:created, %{"HostConfig" => %{"Binds" => binds, "Tmpfs" => tmpfs}}}
    assert tmpfs == %{worktrees => "uid=1000,gid=1000,mode=0700"}
    assert "#{clone_path}:#{clone_path}:ro" in binds
  end

  # Its .git writes into the clone's own git folder, so it keeps the mount every task had before RAIL-203.
  test "a task still on a worktree of its project's clone keeps the whole mount, and a new task beside it does not",
       %{clone_path: clone_path, project: project, role: role, run: run} do
    old_worktree = Path.join([clone_path, ".worktrees", "launch-old"])
    File.mkdir_p!(old_worktree)

    old_issue =
      %Issue{}
      |> Issue.changeset(%{project_id: project.id, identifier: "#{project.key}-2", title: "Old Issue", state: :todo})
      |> Repo.insert!()

    old_task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: old_issue.id,
          stage: :engineer,
          worktree_name: "launch-old",
          worktree_path: old_worktree,
          scratch_path: Path.join(Path.dirname(clone_path), "old-scratch"),
          worktree_slot: 4
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, old_run} =
      Pipeline.create_run(%{task_id: old_task.id, role_id: role.id, status: :starting, started_at: DateTime.utc_now()})

    assert {:ok, %OsProcess{status: :running}} = Tools.start_os_process(old_run, ["-p", "Build it."])
    assert_received {:created, %{"WorkingDir" => ^old_worktree, "HostConfig" => old_host_config}}
    # What config/config.exs gives it.
    assert %{"Binds" => ["/srv/rail:/srv/rail"], "Tmpfs" => %{}} = old_host_config

    assert {:ok, %OsProcess{status: :running}} = Tools.start_os_process(run, ["-p", "Build it."])
    assert_received {:created, %{"HostConfig" => %{"Binds" => binds}}}
    refute "/srv/rail:/srv/rail" in binds
  end

  test "a folder the sandbox would mount that is not there fails it before Docker is asked, naming it", %{
    backend: backend,
    clone_path: clone_path,
    run: run,
    worktree_path: worktree_path
  } do
    File.rm_rf!(clone_path)
    test_pid = self()

    Req.Test.stub(Docker, fn conn ->
      send(test_pid, {:requested, conn.method, conn.request_path})
      Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * @gib})
    end)

    assert {:error, {:spawn_failed, {:bad_cwd, ^clone_path}, %Run{status: :finished}}} =
             Tools.start_os_process(run, ["-p", "x"])

    refute_received {:requested, "POST", "/containers/create"}
    refute File.exists?(clone_path)
    # Nothing of the login was made for a sandbox that never started.
    refute File.exists?(Backend.session_dir(backend, worktree_path))
  end

  # ExUnit runs twice as many cases as the BEAM has schedulers, so CI's are held
  # to its reservation; a flag the project passes comes after, where it wins.
  test "a CI sandbox's BEAM runs as many schedulers as it reserves, not its role", %{run: run} do
    assert {:ok, %OsProcess{kind: :ci, reserved_cpus: 4}} =
             Tools.start_command_process(run, :ci, "mix test", env: %{"ERL_FLAGS" => "+sbwt none"}, reserved_cpus: 4)

    assert_received {:created, %{"Env" => env}}
    assert "ERL_FLAGS=+S 4:4 +sbwt none" in env
  end

  # The machine has 16 CPUs, keeps 3 back and gives the shared browser 2, so the
  # other 11 are the sandbox's to use while idle; its reservation is its weight
  # when others want them too.
  test "weighs the sandbox's CPUs by its reservation up to what the machine can spare, and leaves its memory unlimited",
       %{
         run: run
       } do
    stub(Rail, :sandbox_headroom_cpus, fn -> 3 end)
    stub(Rail, :browser_cpus, fn -> 2 end)

    assert {:ok, %OsProcess{reserved_cpus: 2}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, %{"HostConfig" => host_config}}

    # With nothing to hold it to, a sandbox is what the kernel stops first if the machine runs out.
    assert %{"CpuShares" => 2048, "NanoCpus" => 11_000_000_000, "OomScoreAdj" => 500} = host_config
    refute Map.has_key?(host_config, "Memory")
    refute Map.has_key?(host_config, "MemorySwap")
  end

  test "weighs a sandbox that reserves part of a CPU by that part", %{run: run} do
    {:ok, _role} = Roles.update_role(system_scope(), Repo.preload(run, :role).role, %{reserved_cpus: 0.5})

    assert {:ok, %OsProcess{reserved_cpus: 0.5}} = Tools.start_os_process(run, ["-p", "Build it."])

    assert_received {:created, %{"HostConfig" => %{"CpuShares" => 512}}}
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
             "[rail] Turn 1 needs 2 CPUs, and Rail could not read what this machine has free. " <>
               "It is 1st in line and starts on its own as soon as enough is free."
           ] = run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
  end
end
