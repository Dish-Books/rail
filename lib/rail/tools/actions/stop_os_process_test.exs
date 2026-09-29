defmodule Rail.Tools.Actions.StopOsProcessTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.OsProcess

  setup do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: UXID.generate!(prefix: "tsk"),
        role_id: UXID.generate!(prefix: "rol"),
        status: :running,
        started_at: DateTime.utc_now()
      })

    os_process =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: run.task_id,
        stream_path: "/tmp/stop_os_process.ndjson",
        status: :running,
        started_at: DateTime.utc_now(),
        reserved_cpus: 4,
        reserved_memory_gb: 2
      })
      |> Repo.insert!()

    %{run: run, os_process: os_process}
  end

  test "settles an os process with no live follower, and says who stopped it", %{run: run, os_process: os_process} do
    id = System.unique_integer([:positive])

    {:ok, %{id: user_id} = user} =
      Rail.Users.register_oauth_user(%{
        github_id: "stopper_#{id}",
        login: "stopper_#{id}",
        name: "Lucas Stellet",
        email: "stopper_#{id}@example.com"
      })

    assert {:ok, %OsProcess{}} = Tools.get_active_os_process(run)

    assert {:ok, %OsProcess{status: :finished, ended_reason: :stopped, stopped_by_id: ^user_id, ended_at: %DateTime{}}} =
             Tools.stop_os_process(os_process, grace_period: 50, stopped_by_id: user.id)

    assert {:error, :os_process_not_active} = Tools.get_active_os_process(run)
  end

  describe "with a run waiting in line" do
    setup %{run: run} do
      spec = %{
        "executable" => "/bin/true",
        "args" => [],
        "env" => %{},
        "cwd" => System.tmp_dir!(),
        "stdout_path" => "/dev/null",
        "stderr_path" => "/dev/null"
      }

      waiting =
        Repo.insert!(%OsProcess{
          run_id: run.id,
          task_id: run.task_id,
          stream_path: "/dev/null",
          status: :waiting_for_resources,
          started_at: DateTime.utc_now(),
          queued_at: DateTime.utc_now(),
          reserved_cpus: 2,
          reserved_memory_gb: 2,
          launch: Jason.encode!(spec)
        })

      %{waiting: waiting}
    end

    test "a stopped sandbox frees what it held, and the oldest in line starts", %{
      os_process: os_process,
      waiting: %OsProcess{id: waiting_id}
    } do
      expect(FollowerSupervisor, :start_follower, fn %OsProcess{id: ^waiting_id}, _opts -> {:ok, self()} end)

      assert {:ok, %OsProcess{status: :finished}} = Tools.stop_os_process(os_process, grace_period: 50)
      assert {:ok, %OsProcess{status: :running, launch: nil}} = Tools.get_os_process(waiting_id)
    end

    test "a run stopped while it waits leaves the line, with nothing to kill", %{waiting: waiting} do
      reject(Tools, :terminate_os_process, 2)

      assert {:ok, %OsProcess{status: :finished, ended_reason: :stopped, launch: nil}} =
               Tools.stop_os_process(waiting)
    end
  end
end
