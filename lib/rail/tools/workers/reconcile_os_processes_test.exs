defmodule Rail.Tools.Workers.ReconcileOsProcessesTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Workers.ReconcileOsProcesses

  test "settles a process that died with nobody following it" do
    tmp_dir = Path.join(System.tmp_dir!(), "reconcile_worker_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    {:ok, backend} = Tools.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    project =
      %Project{}
      |> Project.changeset(%{
        name: "Reconcile Project",
        github_repo: "org/reconcile-#{System.unique_integer([:positive])}",
        github_installation_id: System.unique_integer([:positive]),
        linear_team_key: "REC",
        default_branch: "main",
        clone_path: Path.join(tmp_dir, "clone")
      })
      |> Repo.insert!()

    {:ok, role} =
      Roles.create_role(system_scope(), project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "reconcile role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    run =
      %Run{}
      |> Run.changeset(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    stream_path = Path.join(tmp_dir, "orphan.ndjson")
    File.write!(stream_path, ~s({"type":"result","subtype":"success","session_id":"sess-orphan"}\n))
    File.write!("#{stream_path}.err", "")

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: stream_path,
        node: to_string(Node.self()),
        status: :running,
        os_pid: 999_996,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    assert :ok = ReconcileOsProcesses.perform(%Oban.Job{args: %{}})

    assert %OsProcess{status: :adopted_dead} = Repo.reload!(os_process)
    assert {:ok, %Run{status: :finished}} = Pipeline.get_run(run.id)
  end
end
