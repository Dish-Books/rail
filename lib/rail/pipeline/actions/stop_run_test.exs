defmodule Rail.Pipeline.Actions.StopRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_stop_run_1",
              "identifier" => "STP-1",
              "title" => "Stop Run Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Stop Run Issue"})
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

    assert {:ok, %Run{status: :finished, stage_outcome: :in_progress}, nil} = Pipeline.stop_run(run)

    assert ["[rail] Stopped by user."] = Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "an undelivered message comes back rather than being discarded", %{working: working} do
    run = working.(%{pending_chat: "Please add a test"})

    assert {:ok, %Run{pending_chat: nil}, "Please add a test"} = Pipeline.stop_run(run)
  end

  test "stopping a run that was already idle says nothing in the log", %{working: working} do
    run = working.(%{status: :finished})

    assert {:ok, %Run{}, nil} = Pipeline.stop_run(run)
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

    expect(Tools, :stop_os_process, fn %OsProcess{id: id}, _opts ->
      assert id == os_process.id
      {:ok, os_process}
    end)

    assert {:ok, %Run{}, nil} = Pipeline.stop_run(run)
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

    expect(Tools, :stop_os_process, fn %OsProcess{}, _opts ->
      assert %Run{pending_chat: nil} = Repo.get!(Run, run.id)
      {:ok, os_process}
    end)

    assert {:ok, %Run{}, "Please add a test"} = Pipeline.stop_run(run)
  end
end
