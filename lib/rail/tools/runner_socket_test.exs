defmodule Rail.Tools.RunnerSocketTest do
  # The socket's callbacks are called in this process, which stands for the connection, the Follower and the caller.
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerRegistry
  alias Rail.Tools.RunnerRegistry
  alias Rail.Tools.RunnerSocket
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Sandbox

  setup do
    key = "RS#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Socket",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}/clone"
      })

    issue =
      %Issue{}
      |> Issue.changeset(%{project_id: project.id, identifier: "#{key}-1", title: "Socket", state: :todo})
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "socket-1",
          worktree_path: "/tmp/#{key}/socket-1",
          scratch_path: "/tmp/#{key}/scratch"
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        stage: :engineer,
        cli: :claude,
        name: "Engineer",
        model: "claude-socket",
        system_prompt: "Build it."
      })

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    token = "token-#{key}"

    sandbox =
      Repo.insert!(%Sandbox{
        task_id: task.id,
        engine: :docker,
        image: "rail-sandbox:latest",
        volume: "rail-#{key}",
        status: :starting,
        container_id: "c-#{key}",
        token_hash: :crypto.hash(:sha256, token)
      })

    live =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task.id,
        sandbox_id: sandbox.id,
        stream_path: "/dev/null",
        status: :running,
        started_at: DateTime.utc_now()
      })

    settled =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: task.id,
        sandbox_id: sandbox.id,
        stream_path: "/dev/null",
        status: :finished,
        started_at: DateTime.utc_now()
      })

    stub(Rail.Git, :checkout_params, fn _project, %Task{worktree_path: path} -> {:ok, %{"path" => path}} end)
    # A git channel's service runs in the task's repo.
    File.mkdir_p!(Task.repo_path(task))
    on_exit(fn -> File.rm_rf("/tmp/#{key}") end)

    {:ok, state} =
      RunnerSocket.connect([{"x-rail-sandbox-token", token}, {"x-rail-runner", "1.2.3"}])

    %{live: live, run: run, sandbox: sandbox, settled: settled, state: state, task: task, token: token}
  end

  test "a token for no live sandbox, or none at all, is refused before the socket opens", %{
    sandbox: sandbox,
    token: token
  } do
    assert :error = RunnerSocket.connect([{"x-rail-sandbox-token", "nope"}])
    assert :error = RunnerSocket.connect([])

    Repo.update!(Sandbox.changeset(sandbox, %{status: :stopped}))
    assert :error = RunnerSocket.connect([{"x-rail-sandbox-token", token}])
  end

  test "the connection is found by its sandbox, and a newer one for the same sandbox takes its place", %{
    sandbox: sandbox,
    state: state
  } do
    assert RunnerSocket.whereis(sandbox.id) == nil
    test_pid = self()

    old =
      spawn(fn ->
        {:ok, _state} = RunnerSocket.init(state)
        send(test_pid, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    assert RunnerSocket.whereis(sandbox.id) == old

    assert {:ok, _state} = RunnerSocket.init(state)
    refute Process.alive?(old)
    assert RunnerSocket.whereis(sandbox.id) == self()
  end

  test "hello is welcomed, and the task is checked out before anything else goes in", %{sandbox: sandbox, state: state} do
    {:ok, state} = RunnerSocket.init(state)

    assert {:push, [{:text, welcome}, {:text, call}], %RunnerSocket{ready?: false}} =
             runner_hello(state, [])

    assert %{"t" => "welcome", "window" => 1_048_576, "ping_ms" => 20_000} = Jason.decode!(welcome)
    assert %{"t" => "call", "method" => "checkout", "params" => %{"path" => "/tmp/" <> _path}} = Jason.decode!(call)
    assert %Sandbox{connected_at: %DateTime{}, runner_version: "1.2.3", status: :starting} = Repo.reload!(sandbox)
  end

  test "once checked out, a process Rail settled is stopped and let go, and a Follower of one it holds hears", %{
    live: live,
    sandbox: sandbox,
    settled: %OsProcess{id: settled_id} = settled,
    state: state
  } do
    {:ok, _owner} = Registry.register(FollowerRegistry, live.id, nil)

    {:push, _frames, state} =
      runner_hello(state, [%{"id" => settled.id, "state" => "running"}, %{"id" => live.id, "state" => "running"}])

    assert {:push, frames, %RunnerSocket{ready?: true}} = runner_reply(state, "c1", %{"ok" => true, "result" => %{}})

    assert [%{"t" => "signal", "id" => ^settled_id, "signal" => "KILL"}, %{"t" => "done", "id" => ^settled_id}] =
             runner_frames(frames)

    conn = self()
    assert_received {:runner_up, ^conn}
    assert %Sandbox{status: :running, ready_at: %DateTime{}} = Repo.reload!(sandbox)
  end

  test "a settled process the runner already saw exit is only let go", %{settled: settled, state: state} do
    {:push, _frames, state} = runner_hello(state, [%{"id" => settled.id, "state" => "exited"}])
    assert {:push, frames, _state} = runner_reply(state, "c1", %{"ok" => true})
    assert [%{"t" => "done"}] = runner_frames(frames)
  end

  test "a Follower that asks before the checkout is done is answered once it is", %{
    live: %OsProcess{id: id} = live,
    state: state
  } do
    {:push, _frames, state} = runner_hello(state, [%{"id" => live.id, "state" => "running"}])
    assert {:ok, state} = RunnerSocket.handle_info({:follow, self(), live.id, 10, 2, nil}, state)
    assert {:push, frames, _state} = runner_reply(state, "c1", %{"ok" => true})
    assert [%{"t" => "resume", "id" => ^id, "ch" => 1, "out" => 10, "err" => 2}] = runner_frames(frames)
  end

  test "a task whose checkout Rail cannot describe fails what waits on it, and starts nothing", %{state: state} do
    stub(Rail.Git, :checkout_params, fn _project, _task -> {:error, "/w/.env: permission denied"} end)
    {:ok, state} = RunnerSocket.handle_info({:follow, self(), "proc_early", 0, 0, nil}, state)

    assert {:push, [{:text, welcome}], %RunnerSocket{ready?: false}} = runner_hello(state, [])
    assert %{"t" => "welcome"} = Jason.decode!(welcome)

    assert_received {:runner_failed, "proc_early",
                     "Could not check the task out in its sandbox: /w/.env: permission denied"}
  end

  test "a checkout that fails fails every process waiting on it, and any that asks after", %{
    live: live,
    state: state
  } do
    {:push, _frames, state} = runner_hello(state, [])
    {:ok, state} = RunnerSocket.handle_info({:follow, self(), live.id, 0, 0, nil}, state)

    assert {:ok, state} = runner_reply(state, "c1", %{"ok" => false, "error" => "no such branch"})
    assert_received {:runner_failed, _id, "Could not check the task out in its sandbox: no such branch"}

    assert {:ok, _state} = RunnerSocket.handle_info({:follow, self(), "proc_later", 0, 0, nil}, state)
    assert_received {:runner_failed, "proc_later", "Could not check the task out" <> _rest}
  end

  test "a process the runner does not hold starts from its exec, or is lost without one", %{state: state} do
    state = runner_ready(state, [])
    exec = %{"argv" => ["true"], "env" => %{}, "cwd" => "/w", "files" => [], "stdin" => nil, "stderr" => "merge"}

    assert {:push, frames, state} = RunnerSocket.handle_info({:follow, self(), "proc_new", 0, 0, exec}, state)

    assert [%{"t" => "exec", "id" => "proc_new", "ch" => 1, "argv" => ["true"], "stderr" => "merge"}] =
             runner_frames(frames)

    # Known now, so a second Follower resumes it rather than starting it twice.
    assert {:push, frames, state} = RunnerSocket.handle_info({:follow, self(), "proc_new", 0, 0, exec}, state)
    assert [%{"t" => "resume", "ch" => 3}] = runner_frames(frames)

    assert {:push, [], _state} = RunnerSocket.handle_info({:follow, self(), "proc_gone", 0, 0, nil}, state)
    assert_received {:runner_lost, "proc_gone"}
  end

  test "a process's output goes to its Follower, and what the Follower says is safe goes back", %{
    live: %OsProcess{id: id},
    state: state
  } do
    state = runner_ready(state, [%{"id" => id, "state" => "running"}])
    {:push, _resume, state} = RunnerSocket.handle_info({:follow, self(), id, 0, 0, nil}, state)

    assert {:ok, state} = RunnerSocket.handle_in({<<1::32, 1::8, 0::64, "line\n">>, opcode: :binary}, state)
    assert_received {:runner_data, ^id, 1, 0, "line\n"}

    assert {:push, frames, state} = RunnerSocket.handle_info({:ack_proc, id, 1, 5}, state)
    assert [%{"t" => "ack", "ch" => 1, "stream" => 1, "offset" => 5}] = runner_frames(frames)

    assert {:ok, _state} = runner_message(state, %{"t" => "started", "id" => id, "pid" => 42})
    assert_received {:runner_started, ^id, 42}

    assert {:ok, _state} =
             runner_message(state, %{
               "t" => "exit",
               "id" => id,
               "code" => -1,
               "signal" => "KILL",
               "oom" => true,
               "out" => 5,
               "err" => 0
             })

    assert_received {:runner_exit, ^id, %{code: 137, oom: true, out: 5, err: 0}}

    assert {:ok, _state} = runner_message(state, %{"t" => "exit", "id" => id, "code" => 3, "signal" => nil})
    assert_received {:runner_exit, ^id, %{code: 3, oom: false}}

    assert {:push, frames, %RunnerSocket{procs: procs} = state} = RunnerSocket.handle_info({:done, id}, state)
    assert [%{"t" => "done", "id" => ^id}] = runner_frames(frames)
    assert Enum.empty?(procs)

    # With nobody following, output and acks go nowhere.
    assert {:ok, _state} = RunnerSocket.handle_in({<<1::32, 1::8, 5::64, "more">>, opcode: :binary}, state)
    refute_received {:runner_data, _id, _stream, _offset, _bytes}
    assert {:ok, _state} = RunnerSocket.handle_info({:ack_proc, id, 1, 9}, state)
  end

  test "an exit nobody follows is let go when Rail settled it, and kept for Boot when not", %{
    live: live,
    settled: settled,
    state: state
  } do
    state = runner_ready(state, [])
    assert {:push, frames, _state} = runner_message(state, %{"t" => "exit", "id" => settled.id, "code" => 0})
    assert [%{"t" => "done"}] = runner_frames(frames)
    assert {:ok, _state} = runner_message(state, %{"t" => "exit", "id" => live.id, "code" => 0})
    assert {:ok, _state} = runner_message(state, %{"t" => "started", "id" => live.id, "pid" => 7})
    refute_received {:runner_started, _id, _pid}
  end

  test "a Follower that goes away is forgotten", %{live: %OsProcess{id: id}, state: state} do
    state = runner_ready(state, [%{"id" => id, "state" => "running"}])
    follower = spawn(fn -> :ok end)
    {:push, _frames, state} = RunnerSocket.handle_info({:follow, follower, id, 0, 0, nil}, state)

    assert {:ok, %RunnerSocket{procs: procs, chans: chans}} =
             RunnerSocket.handle_info({:DOWN, make_ref(), :process, follower, :normal}, state)

    assert Enum.empty?(procs) and chans == %{}
  end

  test "calls wait for the runner's reply", %{sandbox: sandbox, state: state} do
    assert {:error, :not_running} = RunnerSocket.call(sandbox.id, "sync", %{})

    ref = make_ref()
    assert {:ok, not_ready} = RunnerSocket.handle_info({:call, self(), ref, "sync", %{}}, state)
    assert_received {^ref, {:error, :not_running}}

    state = runner_ready(not_ready, [])
    assert {:push, [frame], state} = RunnerSocket.handle_info({:call, self(), ref, "sync", %{"path" => "/w"}}, state)
    assert [%{"t" => "call", "id" => "c2", "method" => "sync", "params" => %{"path" => "/w"}}] = runner_frames([frame])

    assert {:ok, state} = runner_reply(state, "c2", %{"ok" => true, "result" => %{"head" => "abc"}})
    assert_received {^ref, {:ok, %{"head" => "abc"}}}

    {:push, _frame, state} = RunnerSocket.handle_info({:call, self(), ref, "read", %{}}, state)
    assert {:ok, state} = runner_reply(state, "c3", %{"ok" => false, "error" => "no such file"})
    assert_received {^ref, {:error, "no such file"}}

    # A reply to nothing Rail asked is dropped.
    assert {:ok, _state} = runner_reply(state, "c99", %{"ok" => true})
  end

  test "a call is answered by the connection, and not waited on past its timeout or the connection's end", %{
    sandbox: sandbox
  } do
    test_pid = self()

    conn =
      spawn(fn ->
        Registry.register(RunnerRegistry, sandbox.id, nil)
        send(test_pid, :registered)

        receive do
          {:call, from, ref, "sync", _params} -> send(from, {ref, {:ok, %{"head" => "abc"}}})
        end

        receive do
          {:call, _from, _ref, "slow", _params} -> receive(do: (:never -> :ok))
        end
      end)

    assert_receive :registered
    assert {:ok, %{"head" => "abc"}} = RunnerSocket.call(sandbox.id, "sync", %{})
    assert {:error, :timeout} = RunnerSocket.call(sandbox.id, "slow", %{}, 10)
    Process.exit(conn, :kill)

    spawn(fn ->
      Registry.register(RunnerRegistry, sandbox.id, nil)
      send(test_pid, :registered)
      receive(do: ({:call, _from, _ref, _method, _params} -> exit(:boom)))
    end)

    assert_receive :registered
    assert {:error, :not_running} = RunnerSocket.call(sandbox.id, "sync", %{})
  end

  test "signals reach a connected runner, and are nothing without one", %{sandbox: sandbox, state: state} do
    assert :ok = RunnerSocket.signal(sandbox.id, "proc_a", "TERM")
    refute_received {:signal, _id, _signal}

    {:ok, state} = RunnerSocket.init(state)
    assert :ok = RunnerSocket.signal(sandbox.id, "proc_a", "TERM")
    assert_received {:signal, "proc_a", "TERM"} = message

    assert {:push, frames, _state} = RunnerSocket.handle_info(message, state)
    assert [%{"t" => "signal", "id" => "proc_a", "signal" => "TERM"}] = runner_frames(frames)
  end

  test "a commit to sign is signed by Rail and the signature sent back", %{state: state, task: %Task{id: task_id}} do
    stub(Rail.Git, :sign_commit, fn %Task{id: ^task_id}, "tree abc\n" -> {:ok, "-----BEGIN SSH SIGNATURE-----"} end)

    assert {:ok, state} = runner_message(state, %{"t" => "sign", "id" => "s1", "payload" => Base.encode64("tree abc\n")})
    assert_receive {:signed, "s1", {:ok, signature}} = signed
    assert signature =~ "SSH SIGNATURE"
    assert {:push, frames, _state} = RunnerSocket.handle_info(signed, state)
    assert [%{"t" => "signed", "id" => "s1", "signature" => "-----BEGIN SSH SIGNATURE-----"}] = runner_frames(frames)

    assert {:ok, state} = runner_message(state, %{"t" => "sign", "id" => "s2", "payload" => "%%%"})
    assert_receive {:signed, "s2", {:error, "the payload is not base64"}} = refused
    assert {:push, frames, _state} = RunnerSocket.handle_info(refused, state)
    assert [%{"t" => "signed", "id" => "s2", "error" => "the payload is not base64"}] = runner_frames(frames)
  end

  test "a git channel is bridged to the service Rail runs on the task's repo", %{state: state} do
    stub(Rail.Git, :git_service, fn %Task{}, "git-upload-pack" -> {System.find_executable("cat"), [], %{"A" => "1"}} end)

    assert {:ok, state} =
             runner_message(state, %{"t" => "open", "ch" => 2, "kind" => "git", "service" => "git-upload-pack"})

    assert {:push, [{:text, ack}], state} =
             RunnerSocket.handle_in({<<2::32, 0::8, 0::64, "0009want\n">>, opcode: :binary}, state)

    assert %{"t" => "ack", "ch" => 2, "stream" => 0, "offset" => 9} = Jason.decode!(ack)

    %{port: port} = state.chans[2]
    assert_receive {^port, {:data, "0009want\n"}} = data
    assert {:push, [{:binary, <<2::32, 0::8, 0::64, "0009want\n">>}], state} = RunnerSocket.handle_info(data, state)

    assert {:push, [], state} =
             RunnerSocket.handle_info({port, {:exit_status, 0}}, %{
               state
               | chans: Map.update!(state.chans, 2, &%{&1 | queue: "x", sent: 1_048_576})
             })

    assert {:push, [{:binary, <<2::32, 0::8, 1_048_576::64, "x">>}, {:text, close}], %RunnerSocket{chans: chans} = state} =
             runner_message(state, %{"t" => "ack", "ch" => 2, "stream" => 0, "offset" => 1_048_576})

    assert %{"t" => "close", "ch" => 2, "code" => 0} = Jason.decode!(close)
    assert Enum.empty?(chans)

    # A port Rail no longer bridges says nothing more.
    assert {:ok, _state} = RunnerSocket.handle_info({port, {:data, "late"}}, state)
    assert {:ok, _state} = RunnerSocket.handle_info({port, {:exit_status, 0}}, state)
    assert {:ok, _state} = runner_message(state, %{"t" => "ack", "ch" => 2, "stream" => 0, "offset" => 1})
  end

  test "a git service's output past the runner's window waits for its ack", %{state: state} do
    stub(Rail.Git, :git_service, fn %Task{}, _service -> {System.find_executable("cat"), [], %{}} end)
    {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 2, "kind" => "git", "service" => "git-upload-pack"})
    %{port: port} = state.chans[2]

    big = :binary.copy("a", 1_048_576 + 10)

    assert {:push, frames, %RunnerSocket{chans: %{2 => %{queue: "aaaaaaaaaa"}}} = state} =
             RunnerSocket.handle_info({port, {:data, big}}, state)

    assert length(frames) == 16

    assert {:push, [{:binary, <<2::32, 0::8, 1_048_576::64, rest::binary>>}], _state} =
             runner_message(state, %{"t" => "ack", "ch" => 2, "stream" => 0, "offset" => 65_536})

    assert byte_size(rest) == 10
  end

  test "a push reaches receive-pack only once Rail allowed every ref it updates", %{state: state} do
    stub(Rail.Git, :git_service, fn %Task{}, "git-receive-pack" -> {System.find_executable("cat"), [], %{}} end)

    stub(Rail.Git, :check_push_refs, fn %Task{}, updates ->
      if Enum.all?(updates, fn {_old, _new, ref} -> ref == "refs/heads/socket-1" end),
        do: :ok,
        else: {:error, updates |> hd() |> elem(2)}
    end)

    {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 2, "kind" => "git", "service" => "git-receive-pack"})
    shallow = pkt_line("shallow #{String.duplicate("1", 40)}\n")
    command = pkt_line("#{String.duplicate("0", 40)} #{String.duplicate("a", 40)} refs/heads/socket-1\0report-status\n")
    push = shallow <> command <> "0000PACK"
    <<first::binary-size(10), second::binary>> = push

    # Until the flush, nothing reaches receive-pack.
    assert {:push, [_ack], state} =
             RunnerSocket.handle_in({<<2::32, 0::8, 0::64, first::binary>>, opcode: :binary}, state)

    refute_receive {_port, {:data, _bytes}}, 50

    assert {:push, [_ack], state} =
             RunnerSocket.handle_in({<<2::32, 0::8, 10::64, second::binary>>, opcode: :binary}, state)

    assert_receive {_port, {:data, data}}
    assert String.ends_with?(push, data)

    {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 4, "kind" => "git", "service" => "git-receive-pack"})
    refused = pkt_line("#{String.duplicate("0", 40)} #{String.duplicate("a", 40)} refs/heads/main\n") <> "0000"

    assert {:push, [{:text, close}], state} =
             RunnerSocket.handle_in({<<4::32, 0::8, 0::64, refused::binary>>, opcode: :binary}, state)

    assert %{"t" => "close", "ch" => 4, "error" => "Rail takes pushes to its branch" <> _rest} = Jason.decode!(close)
    refute Map.has_key?(state.chans, 4)

    {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 8, "kind" => "git", "service" => "git-receive-pack"})

    assert {:push, [_ack], %RunnerSocket{chans: %{8 => %{commands: "00"}}} = state} =
             RunnerSocket.handle_in({<<8::32, 0::8, 0::64, "00">>, opcode: :binary}, state)

    for garbage <- ["zzzz", "0003", pkt_line("one two\n") <> "0000"] do
      {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 6, "kind" => "git", "service" => "git-receive-pack"})

      assert {:push, [{:text, close}], _state} =
               RunnerSocket.handle_in({<<6::32, 0::8, 0::64, garbage::binary>>, opcode: :binary}, state)

      assert %{"error" => "Rail takes pushes" <> _rest} = Jason.decode!(close)
    end
  end

  test "a channel the runner closes, or one of a kind Rail has not yet, is let go", %{state: state} do
    stub(Rail.Git, :git_service, fn %Task{}, _service -> {System.find_executable("cat"), [], %{}} end)
    {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 2, "kind" => "git", "service" => "git-upload-pack"})
    %{port: port} = state.chans[2]

    assert {:ok, state} = runner_message(state, %{"t" => "close", "ch" => 2})
    refute Port.info(port)
    assert {:ok, state} = runner_message(state, %{"t" => "close", "ch" => 2})

    assert {:push, frames, state} = runner_message(state, %{"t" => "open", "ch" => 4, "kind" => "mcp"})
    assert [%{"t" => "close", "ch" => 4, "error" => "unsupported"}] = runner_frames(frames)

    assert {:ok, ^state} = runner_message(state, %{"t" => "eof", "ch" => 4, "stream" => 0})
    assert {:ok, ^state} = RunnerSocket.handle_in({<<9::32, 0::8, 0::64, "x">>, opcode: :binary}, state)
    assert {:ok, ^state} = RunnerSocket.handle_info(:unexpected, state)
    assert {:ok, ^state} = RunnerSocket.handle_control({"ping", opcode: :ping}, state)
  end

  test "a connection that ends tells each Follower, and closes the git it bridged", %{
    live: %OsProcess{id: id},
    state: state
  } do
    stub(Rail.Git, :git_service, fn %Task{}, _service -> {System.find_executable("cat"), [], %{}} end)
    state = runner_ready(state, [%{"id" => id, "state" => "running"}])
    {:push, _frames, state} = RunnerSocket.handle_info({:follow, self(), id, 0, 0, nil}, state)
    {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 2, "kind" => "git", "service" => "git-upload-pack"})
    %{port: port} = state.chans[2]

    # One already closed is let be.
    {:ok, state} = runner_message(state, %{"t" => "open", "ch" => 4, "kind" => "git", "service" => "git-upload-pack"})
    Port.close(state.chans[4].port)
    assert :ok = RunnerSocket.terminate(:closed, state)
    assert_received {:runner_down, ^id}
    refute Port.info(port)
  end

  test "Tools.call_sandbox calls the runner of the task's running sandbox only", %{sandbox: sandbox, task: task} do
    assert {:error, :not_running} = Tools.call_sandbox(task, "sync", %{})

    Repo.update!(Sandbox.changeset(sandbox, %{status: :running}))
    test_pid = self()

    spawn(fn ->
      Registry.register(RunnerRegistry, sandbox.id, nil)
      send(test_pid, :registered)
      receive(do: ({:call, from, ref, "sync", %{"x" => 1}} -> send(from, {ref, {:ok, %{}}})))
    end)

    assert_receive :registered
    assert {:ok, %{}} = Tools.call_sandbox(task, "sync", %{"x" => 1}, timeout: 1_000)
  end
end
