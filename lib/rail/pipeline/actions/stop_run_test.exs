defmodule Rail.Pipeline.Actions.StopRunTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Stop Run Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    working = fn attrs ->
      {:ok, run} =
        Pipeline.create_run(
          Map.merge(
            %{
              task_id: task.id,
              role_id: role.id,
              status: :running,
              conversation_id: "sess_stop_run",
              started_at: DateTime.utc_now()
            },
            attrs
          )
        )

      run
    end

    %{project: project, task: task, role: role, working: working}
  end

  test "stopping a working run says so in the log and leaves it stopped", %{working: working} do
    run = working.(%{})

    assert {:ok, %Run{status: :finished, stage_outcome: :in_progress}, nil} = Pipeline.stop_run(system_scope(), run)

    assert ["[rail] Stopped by user."] = Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "stopping a run waiting in line takes it out of the line and lets the next one start", %{working: working} do
    run = working.(%{status: :waiting_for_resources})
    launch = Jason.encode!(%{"executable" => "/bin/true", "args" => [], "env" => %{}, "cwd" => "/tmp"})

    %OsProcess{id: waiting_id} =
      Repo.insert!(%OsProcess{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: DateTime.utc_now(),
        queued_at: DateTime.utc_now(),
        reserved_cpus: 4,
        launch: launch
      })

    next = working.(%{status: :waiting_for_resources})

    %OsProcess{id: next_id} =
      Repo.insert!(%OsProcess{
        run_id: next.id,
        task_id: next.task_id,
        stream_path: "/dev/null",
        status: :waiting_for_resources,
        started_at: DateTime.utc_now(),
        queued_at: DateTime.shift(DateTime.utc_now(), second: 1),
        reserved_cpus: 4,
        launch: launch
      })

    assert {:ok, %Run{status: :finished}, nil} = Pipeline.stop_run(system_scope(), run)

    assert {:ok, %OsProcess{status: :finished, ended_reason: :stopped}} = Tools.get_os_process(waiting_id)
    assert {:ok, %OsProcess{status: :running}} = Tools.get_os_process(next_id)
    assert {:ok, %Run{status: :running}} = Pipeline.get_run(next.id)
    assert ["[rail] Stopped by user."] = Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  # Plan's worktree setup runs beside its agent on the same run, so stopping the run stops both.
  test "stopping a Plan run stops its agent's turn and the worktree setup beside it", %{
    project: project,
    working: working
  } do
    {:ok, plan} = Roles.get_role(project_id: project.id, stage: :plan)
    run = working.(%{role_id: plan.id, status: :waiting_for_resources})
    launch = Jason.encode!(%{"executable" => "/bin/true", "args" => [], "env" => %{}, "cwd" => "/tmp"})

    # Holds every CPU, so neither stop lets the other into a sandbox meanwhile.
    Repo.insert!(%OsProcess{
      run_id: working.(%{}).id,
      task_id: run.task_id,
      stream_path: "/dev/null",
      status: :running,
      started_at: DateTime.utc_now(),
      reserved_cpus: 4
    })

    [agent_id, setup_id] =
      for {kind, offset} <- [agent: 0, setup: 1] do
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          kind: kind,
          stream_path: "/dev/null",
          status: :waiting_for_resources,
          started_at: DateTime.utc_now(),
          queued_at: DateTime.shift(DateTime.utc_now(), second: offset),
          reserved_cpus: 1,
          launch: launch
        }).id
      end

    assert {:ok, %Run{status: :finished}, nil} = Pipeline.stop_run(system_scope(), run)

    for id <- [agent_id, setup_id] do
      assert {:ok, %OsProcess{status: :finished, ended_reason: :stopped}} = Tools.get_os_process(id)
    end
  end

  # A run that never got a sandbox has no process to settle, so the stop is all there is to announce.
  test "stopping a run waiting in line tells whoever is watching the pipeline", %{task: %{id: task_id}, working: working} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")
    run = working.(%{status: :waiting_for_resources})

    assert {:ok, %Run{status: :finished}, nil} = Pipeline.stop_run(system_scope(), run)
    assert_received {:pipeline_changed, ^task_id}
  end

  test "stopping a run waiting for usage tells the task page watching it", %{working: working} do
    %Run{id: run_id} = run = working.(%{status: :waiting_for_usage})
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert {:ok, %Run{status: :finished}, nil} = Pipeline.stop_run(system_scope(), run)
    assert_received {:run_changed, ^run_id}
  end

  # The latch says the lead's latest turn ended with its review saved, which a turn stopped half way did not.
  test "a Review lead an earlier round latched, messaged and then stopped, reads stopped", %{
    project: project,
    task: task
  } do
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # Git is only ever asked through Rail.Git, so the worktree is a plain directory, on the commit whose sha is all a's
    # with nothing changed against main.
    worktree = Path.join(task.scratch_path, "worktree")
    Enum.each([worktree, worktree <> ".git"], &File.mkdir_p!/1)
    {:ok, task} = Pipeline.update_task(task, %{stage: :review, worktree_path: worktree})

    stub(Git, :branch_fingerprint, fn %{worktree_path: ^worktree} ->
      %{head_sha: String.duplicate("a", 40), dirty_digest: String.duplicate("0", 64)}
    end)

    stub(Git, :load_diff, fn _scope, %{worktree_path: ^worktree}, :branch -> {:ok, []} end)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        conversation_id: "sess_stop_latched_lead",
        started_at: DateTime.utc_now()
      })

    test_pid = self()

    expect(Tools, :start_os_process, fn %Run{id: ^run_id} = spawned, _argv ->
      send(test_pid, :spawned)
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_message(system_scope(), run, "Are you sure about the nil?")
    assert_receive :spawned

    assert {:ok, %Run{stage_outcome: :in_progress} = stopped, nil} = Pipeline.stop_run(system_scope(), run)
    assert :stopped = stopped |> Repo.preload(:questions) |> Run.state()
  end

  test "an undelivered message comes back rather than being discarded", %{working: working} do
    run = working.(%{pending_chat: "Please add a test"})

    assert {:ok, %Run{pending_chat: nil}, "Please add a test"} = Pipeline.stop_run(system_scope(), run)
  end

  test "stopping a run that was already idle says nothing in the log", %{working: working} do
    run = working.(%{status: :finished})

    assert {:ok, %Run{}, nil} = Pipeline.stop_run(system_scope(), run)
    assert Pipeline.list_run_events(run) == []
  end

  test "the live process is killed along with the run", %{working: working} do
    run = working.(%{})

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/stop_run/#{run.id}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    expect(Tools, :stop_os_process, fn %Rail.Scope{}, %OsProcess{id: id}, _opts ->
      assert id == os_process.id
      {:ok, os_process}
    end)

    assert {:ok, %Run{}, nil} = Pipeline.stop_run(system_scope(), run)
  end

  # Killing the process settles the run then and there, and a settle that still
  # found a queued message would send it - so by the time anything is killed the
  # queue is already empty and the text is the caller's alone.
  test "the queue is empty before the process is killed", %{working: working} do
    run = working.(%{pending_chat: "Please add a test"})

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/stop_run/#{run.id}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    expect(Tools, :stop_os_process, fn %Rail.Scope{}, %OsProcess{}, _opts ->
      assert %Run{pending_chat: nil} = Repo.get!(Run, run.id)
      {:ok, os_process}
    end)

    assert {:ok, %Run{}, "Please add a test"} = Pipeline.stop_run(system_scope(), run)
  end
end
