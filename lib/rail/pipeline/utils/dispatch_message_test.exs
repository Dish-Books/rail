defmodule Rail.Pipeline.Utils.DispatchMessageTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DispatchMessage

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_dispatch_message_1",
              "identifier" => "DSP-1",
              "title" => "Dispatch Message Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Dispatch Message Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_dispatch_message",
        pending_chat: "Please also add a test",
        started_at: DateTime.utc_now()
      })

    %{project: project, run: run, run_id: run_id}
  end

  test "sends the queued message and takes it off the run", %{run: run, run_id: run_id} do
    expect(Tools, :start_os_process, fn spawned, argv ->
      assert Enum.any?(argv, &(&1 =~ "Please also add a test"))
      {:ok, %OsProcess{run: spawned}}
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: nil, status: :running} = Repo.reload!(run)
    assert_received {:run_changed, ^run_id}
  end

  # How the last turn ended is not how this one has ended, and a run left wearing
  # an error is a run nothing will ever latch as done.
  test "a person's message starts the count of CI failures sent back over", %{run: run} do
    {:ok, run} = Pipeline.update_run(run, %{ci_failure_streak: 3})

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
    assert %Run{ci_failure_streak: 0} = Repo.reload!(run)
  end

  test "the turn before this one takes its error with it", %{run: run} do
    {:ok, failed} = run |> Run.changeset(%{error: "Error: empty prompt", exit_code: 1}) |> Repo.update()

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %OsProcess{}} = dispatch_message(failed, async: false)
    assert %Run{error: nil, exit_code: nil} = Repo.reload!(failed)
  end

  test "a message that fails to spawn goes back on the run", %{run: run, run_id: run_id} do
    expect(Tools, :start_os_process, fn spawned, _argv -> {:error, {:spawn_failed, :enoent, spawned}} end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert {:error, {:spawn_failed, :enoent}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
    assert_received {:run_changed, ^run_id}
    assert [%RunEvent{line: "[rail] That message was not delivered: " <> _reason}] = Repo.all(RunEvent)
  end

  test "a message held back by disabled dispatch stays queued", %{run: run} do
    expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert {:error, :dispatch_disabled} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
  end

  # A worktree that cannot be made is the message never leaving, and the run has
  # to say so rather than look like it was delivered.
  test "a message with nowhere to run fails the run", %{run: run} do
    expect(Rail.Git, :get_or_create_worktree, fn _project, _task -> {:error, :no_such_branch} end)

    assert {:error, {:worktree_failed, :no_such_branch}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
    assert [%RunEvent{line: "[rail] That message was not delivered: " <> _reason}] = Repo.all(RunEvent)
  end

  test "a run that is gone has nothing to dispatch", %{run: run} do
    Repo.delete!(run)

    assert {:error, :invalid_state} = dispatch_message(run, async: false)
  end

  # Two dispatches can reach one queued message - the human sending it now and
  # the exit of the turn they interrupted - and the one that arrives second finds
  # the row empty. Spawning an agent with no prompt is an error the run then
  # wears, so the second one sends nothing at all.
  test "a queue someone else already emptied spawns nothing", %{run: run} do
    {:ok, drained} = run |> Run.changeset(%{pending_chat: nil}) |> Repo.update()

    reject(&Tools.start_os_process/2)

    assert {:error, :nothing_queued} = dispatch_message(drained, async: false)
  end

  test "a worktree that still needs setting up gets that first, with the message left queued", %{
    project: project,
    run: run
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{worktree_setup_script: "bin/setup"})

    reject(Tools, :start_os_process, 2)

    expect(Tools, :start_command_process, fn spawned, :setup, "./bin/setup", _opts ->
      {:ok, %OsProcess{kind: :setup, run: spawned}}
    end)

    assert {:ok, %OsProcess{kind: :setup}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test", status: :running} = Repo.reload!(run)
  end

  test "a setup that cannot start leaves the message queued and the run failed", %{project: project, run: run} do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{worktree_setup_script: "bin/setup"})

    expect(Tools, :start_command_process, fn _run, :setup, _command, _opts -> {:error, :enoent} end)

    assert {:error, :worktree_setup_failed} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test", status: :failed} = Repo.reload!(run)
  end
end
