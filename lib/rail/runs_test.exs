defmodule Rail.RunsTest do
  use Rail.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Backends.Schemas.Backend
  alias Rail.Runs
  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ClaudeEvents
  alias Rail.Runs.DetectedQuestion
  alias Rail.Runs.Schemas.RunEvent

  test "delegates build_args/1" do
    args =
      Runs.build_args(
        backend: %Backend{name: :claude},
        prompt: "Check types",
        model: "claude-3-7-sonnet"
      )

    assert args == [
             "-p",
             "Check types",
             "--model",
             "claude-3-7-sonnet",
             "--effort",
             "high",
             "--dangerously-skip-permissions",
             "--output-format",
             "stream-json",
             "--verbose"
           ]
  end

  test "delegates build_prompt/1" do
    prompt = Runs.build_prompt(task_description: "Build landing page")
    assert prompt == "Build landing page\n"
  end

  test "delegates detect_question/1 and detect_question/2" do
    assert %DetectedQuestion{} = Runs.detect_question("[QUESTION: Which db?]")
    assert %DetectedQuestion{task_id: "tsk_1"} = Runs.detect_question("[QUESTION: Which db?]", task_id: "tsk_1")
    assert is_nil(Runs.detect_question("Plain prose"))
  end

  test "delegates summarize_tool_input/1 and summarize_tool_input/2" do
    assert Runs.summarize_tool_input(%{"command" => "mix test"}) == "mix test"
    assert Runs.summarize_tool_input("bash", %{"command" => "mix test"}) == "mix test"
  end

  test "delegates transient?/1" do
    assert Runs.transient?("timed out")
    refute Runs.transient?("unrecognized_model")
  end

  test "new_event_state/2 creates Claude or Agy event state" do
    assert %ClaudeEvents{} = Runs.new_event_state(%Backend{name: :claude})

    assert %AgyEvents{} = Runs.new_event_state(%Backend{name: :agy})
  end

  test "parse_line/2 dispatches to appropriate parser" do
    claude_state = Runs.new_event_state(%Backend{name: :claude})
    updated_claude = Runs.parse_line(claude_state, "banner message")
    assert updated_claude.logs == ["banner message"]

    agy_state = Runs.new_event_state(%Backend{name: :agy})
    updated_agy = Runs.parse_line(agy_state, "agy message")
    assert updated_agy.logs == ["agy message"]
  end

  test "parse_event/2 dispatches with state struct" do
    claude_state = Runs.new_event_state(%Backend{name: :claude})

    updated_claude =
      Runs.parse_event(claude_state, %{"type" => "system", "session_id" => "sess-1"})

    assert updated_claude.conversation_id == "sess-1"

    agy_state = Runs.new_event_state(%Backend{name: :agy})

    updated_agy =
      Runs.parse_event(agy_state, %{"event" => "init", "conversation_id" => "conv-1", "init" => %{}})

    assert updated_agy.conversation_id == "conv-1"
  end

  test "parse_event/2 dispatches on the backend" do
    claude_result = Runs.parse_event(%Backend{name: :claude}, %{"type" => "system", "session_id" => "sess-2"})
    assert %ClaudeEvents{conversation_id: "sess-2"} = claude_result

    agy_result =
      Runs.parse_event(%Backend{name: :agy}, %{"event" => "init", "conversation_id" => "conv-2", "init" => %{}})

    assert %AgyEvents{conversation_id: "conv-2"} = agy_result
  end

  test "create_run/1, get_run/1, get_run!/1, update_run/2" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :starting,
        started_at: DateTime.utc_now()
      })

    assert run.id =~ "run_"
    assert Runs.get_run(run.id).id == run.id
    assert Runs.get_run!(run.id).id == run.id
    assert is_nil(Runs.get_run("rr_nonexistent"))

    {:ok, updated} = Runs.update_run(run, %{status: :running})
    assert updated.status == :running
  end

  test "get_os_process/1, get_os_process!/1, list_os_processes/1, list_active_os_processes/1" do
    scope = system_scope()
    unique = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "runs_test_#{unique}")
    File.mkdir_p!(Path.join(tmp_dir, "worktree"))
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, workspace} =
      Rail.Projects.upsert_linear_workspace(scope, %{
        name: "Runs Workspace #{unique}",
        external_id: "lin_ws_runs_#{unique}",
        token: "lin_api_token_runs_#{unique}",
        webhook_secret: "whsec_runs_#{unique}"
      })

    {:ok, project} =
      Rail.Projects.create_project(scope, %{
        name: "Runs Project #{unique}",
        github_repo: "org/runs-#{unique}",
        github_installation_id: unique,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_runs_#{unique}",
        linear_team_key: "RUN#{unique}",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })

    {:ok, backend} =
      Rail.Backends.create_backend(scope, %{name: :claude, executable_path: "/bin/sleep"})

    {:ok, role} =
      Rail.Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    {:ok, task} =
      %Rail.Pipeline.Schemas.Task{id: UXID.generate!(prefix: "tsk")}
      |> Rail.Pipeline.Schemas.Task.changeset(
        %{
          stage: :engineer,
          stage_state: :queued,
          worktree_name: "runs-#{unique}",
          worktree_path: Path.join(tmp_dir, "worktree"),
          scratch_path: Path.join(tmp_dir, "scratch")
        },
        project.id
      )
      |> Repo.insert()

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    task_id = task.id

    {:ok, os_process} =
      Runs.start_os_process(run, :stage, ["5"], allow_fun: fn pid -> Sandbox.allow(Repo, self(), pid) end)

    assert Runs.get_os_process(os_process.id).id == os_process.id
    assert Runs.get_os_process!(os_process.id).id == os_process.id
    assert is_nil(Runs.get_os_process("run_nonexistent"))

    all_runs = Runs.list_os_processes(task_id: task_id)
    assert length(all_runs) == 1
    assert hd(all_runs).id == os_process.id

    node_runs = Runs.list_os_processes(node: os_process.node, status: :running, ignore_unknown: true)
    assert length(node_runs) == 1

    active_runs = Runs.list_active_os_processes(run_id: run.id)
    assert length(active_runs) == 1

    Runs.stop_os_process(os_process.id, grace_period: 50)
  end

  test "list_run_events/2 returns events ordered by seq with optional limit" do
    role_id = UXID.generate!(prefix: "rol")
    task_id = UXID.generate!(prefix: "tsk")

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    Repo.insert!(%RunEvent{run_id: run.id, seq: 1, line: "line 1"})
    Repo.insert!(%RunEvent{run_id: run.id, seq: 2, line: "line 2"})
    Repo.insert!(%RunEvent{run_id: run.id, seq: 3, line: "line 3"})

    events = Runs.list_run_events(run.id)
    assert length(events) == 3
    assert Enum.map(events, & &1.seq) == [1, 2, 3]

    limited = Runs.list_run_events(run.id, limit: 2)
    assert length(limited) == 2
  end

  test "on_os_process_finished/2 broadcasts on PubSub" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "os_processes")

    os_process = %Rail.Runs.Schemas.OsProcess{id: "run_test"}
    outcome = %{exit_code: 0}

    assert {:ok, ^outcome} = Runs.on_os_process_finished(os_process, outcome)
    assert_receive {:os_process_finished, ^os_process, ^outcome}, 500
  end

  test "start_os_process/4 and stop_os_process/2 through Runs context" do
    scope = system_scope()
    unique = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "runs_test_#{unique}")
    File.mkdir_p!(Path.join(tmp_dir, "worktree"))
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, workspace} =
      Rail.Projects.upsert_linear_workspace(scope, %{
        name: "Runs Workspace #{unique}",
        external_id: "lin_ws_runs_#{unique}",
        token: "lin_api_token_runs_#{unique}",
        webhook_secret: "whsec_runs_#{unique}"
      })

    {:ok, project} =
      Rail.Projects.create_project(scope, %{
        name: "Runs Project #{unique}",
        github_repo: "org/runs-#{unique}",
        github_installation_id: unique,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_runs_#{unique}",
        linear_team_key: "RUN#{unique}",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })

    {:ok, backend} =
      Rail.Backends.create_backend(scope, %{name: :claude, executable_path: "/bin/sleep"})

    {:ok, role} =
      Rail.Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    {:ok, task} =
      %Rail.Pipeline.Schemas.Task{id: UXID.generate!(prefix: "tsk")}
      |> Rail.Pipeline.Schemas.Task.changeset(
        %{
          stage: :engineer,
          stage_state: :queued,
          worktree_name: "runs-#{unique}",
          worktree_path: Path.join(tmp_dir, "worktree"),
          scratch_path: Path.join(tmp_dir, "scratch")
        },
        project.id
      )
      |> Repo.insert()

    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    task_id = task.id

    {:ok, os_process} =
      Runs.start_os_process(run, :stage, ["30"], allow_fun: fn pid -> Sandbox.allow(Repo, self(), pid) end)

    follower_pid = Runs.get_follower_pid(os_process.id)
    assert is_pid(follower_pid)
    assert Process.alive?(follower_pid)
    assert Runs.is_running?(task_id)
    refute Runs.is_running?("tsk_nonexistent")
    refute Runs.is_running?(123)

    {:ok, stopped} = Runs.stop_os_process(task_id, grace_period: 50)
    assert stopped.status == :finished
    refute Runs.is_running?(task_id)
  end

  test "adopt_live_os_processes/1 delegates to Boot" do
    assert Runs.adopt_live_os_processes(node: "empty_node") == []
  end

  test "append_run_event/2 accepts %Run{} struct and persists sequentially" do
    task_id = UXID.generate!(prefix: "tsk")
    role_id = UXID.generate!(prefix: "rol")

    {:ok, run} =
      Runs.create_run(%{
        task_id: task_id,
        role_id: role_id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert %RunEvent{line: "Line from struct", seq: 1} =
             Runs.append_run_event(run, "Line from struct")

    assert Runs.chat_prompt("Hi") =~ "Human message:\nHi"
  end

  test "get_latest_run_for_task/2 returns latest run" do
    task_id = UXID.generate!(prefix: "tsk")

    assert {:error, :not_found} = Runs.get_latest_run_for_task(task_id)
    assert {:error, :not_found} = Runs.get_latest_run_for_task(nil)

    role_id_1 = UXID.generate!(prefix: "rol")
    role_id_2 = UXID.generate!(prefix: "rol")
    now = DateTime.utc_now()

    {:ok, %{id: expected_1_id}} =
      Runs.create_run(%{task_id: task_id, role_id: role_id_1, status: :finished, started_at: now})

    {:ok, %{id: expected_any_id}} =
      Runs.create_run(%{task_id: task_id, role_id: role_id_2, status: :finished, started_at: now})

    assert {:ok, %{id: ^expected_any_id}} = Runs.get_latest_run_for_task(task_id)
    assert {:ok, %{id: ^expected_1_id}} = Runs.get_latest_run_for_task(task_id, role_id_1)

    other_role_id = UXID.generate!(prefix: "rol")
    assert {:error, :not_found} = Runs.get_latest_run_for_task(task_id, other_role_id)
    assert {:error, :not_found} = Runs.get_latest_run_for_task(task_id, :reviewer)
  end
end
