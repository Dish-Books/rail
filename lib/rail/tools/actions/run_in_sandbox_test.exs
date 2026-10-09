defmodule Rail.Tools.Actions.RunInSandboxTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_ris_#{System.unique_integer([:positive])}",
              "identifier" => "RIS-1",
              "title" => "Seed"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Seed"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    task = task |> Ecto.Changeset.change(worktree_slot: 3) |> Repo.update!()
    File.mkdir_p!(task.worktree_path)
    on_exit(fn -> File.rm_rf(task.worktree_path) end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: Path.join(task.scratch_path, "stream.ndjson"),
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    %{task: task, os_process: os_process}
  end

  test "beside Rail, runs from the worktree root with the worktree's own ports", %{task: task, os_process: os_process} do
    assert {:ok, %{output: output, exit_code: 0}} =
             Tools.run_in_sandbox(os_process, ~s(pwd; echo "$RAIL_PORT_BASE"; echo oops >&2))

    assert [cwd, "20300", "oops"] = String.split(output, "\n", trim: true)
    assert File.stat!(cwd).inode == File.stat!(task.worktree_path).inode
  end

  test "says how a command that failed exited", %{os_process: os_process} do
    assert {:ok, %{output: "no\n", exit_code: 4}} = Tools.run_in_sandbox(os_process, "echo no; exit 4")
  end

  # A seed is a script the branch wrote, so what it prints is not to be trusted to be text.
  test "output that is not UTF-8 comes back readable", %{os_process: os_process} do
    assert {:ok, %{output: "a�b", exit_code: 0}} = Tools.run_in_sandbox(os_process, ~s(printf 'a\\377b'))
  end

  test "a command past its limit is stopped", %{os_process: os_process} do
    assert {:error, :timeout} = Tools.run_in_sandbox(os_process, "sleep 5", timeout_ms: 100)
  end

  test "under Docker, runs inside the agent's own container", %{task: %{worktree_path: worktree}, os_process: os_process} do
    os_process = %{os_process | runtime: :docker, container_id: "c0ffee"}

    Req.Test.expect(Docker, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/containers/c0ffee/exec"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert %{
                   "Cmd" => ["timeout", "-k", "5", "120.0", "/bin/sh", "-c", "scripts/seed"],
                   "WorkingDir" => ^worktree,
                   "Env" => env
                 } =
                   Jason.decode!(body)

          assert "RAIL_PORT_BASE=20300" in env
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "exec1"})

        {"POST", "/exec/exec1/start"} ->
          Plug.Conn.send_resp(conn, 200, <<1, 0, 0, 0, 3::32, "ok\n">>)

        {"GET", "/exec/exec1/json"} ->
          Req.Test.json(conn, %{"ExitCode" => 0})
      end
    end)

    assert {:ok, %{output: "ok\n", exit_code: 0}} = Tools.run_in_sandbox(os_process, "scripts/seed")
  end

  test "under Docker, a command past its limit is stopped", %{os_process: os_process} do
    os_process = %{os_process | runtime: :docker, container_id: "c0ffee"}

    Req.Test.stub(Docker, fn conn ->
      case conn.request_path do
        "/containers/c0ffee/exec" ->
          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "exec1"})

        "/exec/exec1/start" ->
          Process.sleep(1_000)
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    assert {:error, :timeout} = Tools.run_in_sandbox(os_process, "sleep 5", timeout_ms: 100)
  end

  test "under Docker, what Docker refused is said", %{os_process: os_process} do
    os_process = %{os_process | runtime: :docker, container_id: "gone"}

    Req.Test.expect(Docker, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such container: gone"})
    end)

    assert {:error, {:docker_api_error, 404, _body}} = Tools.run_in_sandbox(os_process, "scripts/seed")
  end
end
