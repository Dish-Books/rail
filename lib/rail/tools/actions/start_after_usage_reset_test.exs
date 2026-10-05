defmodule Rail.Tools.Actions.StartAfterUsageResetTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.FollowerSupervisor
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    unique = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "usage_reset_test_#{unique}")
    File.mkdir_p!(Path.join(tmp_dir, "worktree"))
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    model = "claude-reset-#{unique}"
    reset = DateTime.utc_now() |> DateTime.shift(hour: 2) |> DateTime.truncate(:second)

    {:ok, account} =
      Tools.create_backend(system_scope(), %{
        name: :claude,
        label: "work",
        executable_path: "/usr/bin/true",
        models: [%{id: model}]
      })

    # Its 5-hour window is spent, as the probe stored it.
    account =
      account
      |> Backend.usage_changeset(%{
        name: :claude,
        status: :ready,
        usage: [
          %{
            name: "Session",
            details: %{
              "windows" => [
                %{"label" => "Session", "remaining_percent" => 0.0, "resets_at" => DateTime.to_iso8601(reset)}
              ]
            }
          }
        ]
      })
      |> Repo.update!()

    {:ok, seeded} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, role} = Roles.update_role(system_scope(), seeded, %{model: model})

    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_reset_#{unique}",
        identifier: "RST#{unique}-1",
        title: "Reset Issue",
        state: :backlog
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "reset-#{unique}",
          worktree_path: Path.join(tmp_dir, "worktree"),
          scratch_path: Path.join(tmp_dir, "scratch")
        },
        project.id
      )
      |> Repo.insert!()

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :starting, started_at: DateTime.utc_now()})

    {:ok, %OsProcess{status: :waiting_for_usage} = waiting} = Tools.start_os_process(run, ["2"])
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    %{account: account, reset: reset, run: run, waiting: waiting}
  end

  test "once its reset has passed, the waiting turn starts on its own and the page is told", %{
    account: %Backend{id: account_id} = account,
    run: %Run{id: run_id},
    waiting: waiting
  } do
    passed =
      account.usage
      |> Enum.map(&Map.from_struct/1)
      |> put_in([Access.at(0), :details, "windows", Access.at(0), "resets_at"], "2026-01-01T00:00:00Z")

    account |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: passed}) |> Repo.update!()

    expect(Tools, :spawn_os_process, fn "/usr/bin/true", ["2"], _opts -> {:ok, nil, 4250} end)
    expect(FollowerSupervisor, :start_follower, fn _os_process, _opts -> {:ok, self()} end)

    assert {:ok, %OsProcess{status: :running, backend_id: ^account_id, launch: nil}} =
             Tools.start_after_usage_reset(waiting.id)

    assert %Run{status: :running} = Repo.get!(Run, run_id)
    assert_receive {:run_changed, ^run_id}
  end

  test "a turn whose account is still used up waits again, for the next reset", %{reset: reset, waiting: waiting} do
    reject(Tools, :spawn_os_process, 3)

    assert {:waiting_for_usage, ^reset} = Tools.start_after_usage_reset(waiting.id)
    assert %OsProcess{status: :waiting_for_usage, launch: "" <> _kept} = Repo.get!(OsProcess, waiting.id)
  end

  test "a stopped turn never starts", %{waiting: waiting} do
    reject(Tools, :spawn_os_process, 3)
    {:ok, _stopped} = Tools.stop_os_process(system_scope(), waiting)

    assert {:error, :not_waiting} = Tools.start_after_usage_reset(waiting.id)
    assert %OsProcess{status: :finished, ended_reason: :stopped} = Repo.get!(OsProcess, waiting.id)
  end

  test "a turn whose account has since been signed out is held in line on it until it is signed in", %{
    account: %Backend{id: account_id} = account,
    run: %Run{id: run_id},
    waiting: waiting
  } do
    account |> Backend.usage_changeset(%{name: :claude, status: :signed_out}) |> Repo.update!()
    reject(Tools, :spawn_os_process, 3)

    assert {:ok, %OsProcess{status: :waiting_for_resources, backend_id: ^account_id}} =
             Tools.start_after_usage_reset(waiting.id)

    assert %Run{status: :waiting_for_resources} = Repo.get!(Run, run_id)
  end

  test "a turn whose model no account offers any more fails its run, and the page is told", %{
    account: account,
    run: %Run{id: run_id},
    waiting: waiting
  } do
    {:ok, _no_model} = Tools.update_backend(system_scope(), account, %{models: []})

    assert {:error, "No signed-in account offers " <> _how} = Tools.start_after_usage_reset(waiting.id)
    assert %Run{status: :finished, error: "No signed-in account offers " <> _rest} = Repo.get!(Run, run_id)
    assert_receive {:run_changed, ^run_id}
  end

  test "a turn whose account's CLI has gone is settled by the missing binary check", %{
    account: account,
    run: %Run{id: run_id},
    waiting: waiting
  } do
    {:ok, account} = Tools.update_backend(system_scope(), account, %{executable_path: "/nonexistent/claude"})
    account |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: []}) |> Repo.update!()

    assert {:error, {:missing_binary, "/nonexistent/claude", _row}} = Tools.start_after_usage_reset(waiting.id)
    assert %Run{error: "No such CLI binary: /nonexistent/claude"} = Repo.get!(Run, run_id)
    assert_receive {:run_changed, ^run_id}
  end

  test "a turn whose sandbox will not start fails its run with why", %{
    account: account,
    run: %Run{id: run_id},
    waiting: waiting
  } do
    account |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: []}) |> Repo.update!()
    expect(Tools, :spawn_os_process, fn _executable, _args, _opts -> {:error, :eacces} end)

    assert {:error, :eacces} = Tools.start_after_usage_reset(waiting.id)
    assert %Run{error: "Could not start its sandbox: :eacces"} = Repo.get!(Run, run_id)
  end

  test "a turn that finds the machine full joins the sandbox line instead", %{
    account: account,
    run: %Run{id: run_id} = run,
    waiting: waiting
  } do
    account |> Backend.usage_changeset(%{name: :claude, status: :ready, usage: []}) |> Repo.update!()

    Repo.insert!(%OsProcess{
      run_id: run.id,
      task_id: run.task_id,
      stream_path: "/dev/null",
      status: :running,
      started_at: DateTime.utc_now(),
      reserved_cpus: 4,
      reserved_memory_gb: 8
    })

    reject(Tools, :spawn_os_process, 3)

    assert {:ok, %OsProcess{status: :waiting_for_resources}} = Tools.start_after_usage_reset(waiting.id)
    assert %Run{status: :waiting_for_resources} = Repo.get!(Run, run_id)
  end
end
