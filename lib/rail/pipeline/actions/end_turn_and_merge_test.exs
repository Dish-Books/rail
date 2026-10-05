defmodule Rail.Pipeline.Actions.EndTurnAndMergeTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_etm_1", "identifier" => "ETM-1", "title" => "End Turn Merge"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "End Turn Merge"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_end_turn_merge",
        started_at: DateTime.utc_now()
      })

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/end_turn_merge/#{run.id}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Req.Test.stub(Rail.GitHub.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    %{task: task, run: run, repo: repo, os_process: os_process}
  end

  test "an accepted request stops the turn and merges the default branch in, pushing a clean merge", %{
    task: task,
    run: %Run{id: run_id},
    os_process: %OsProcess{id: os_process_id} = os_process
  } do
    test_pid = self()

    expect(Tools, :stop_os_process, fn _scope, %OsProcess{id: ^os_process_id}, _opts ->
      send(test_pid, :stopped)
      {:ok, os_process}
    end)

    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    expect(Git, :up_to_date_with?, fn _path, "main" -> false end)
    expect(Git, :merge_default_branch, fn _scope, %Task{} -> :ok end)
    expect(Git, :push_branch, fn _scope, _task -> :ok end)

    assert {:ok, :merging} = Pipeline.end_turn_and_merge(task, os_process)
    assert_received :stopped
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{status: :finished, stage_outcome: :done, error: nil} = Repo.get!(Run, run_id)
  end

  test "conflicts start the engineer's turn to resolve them", %{
    task: task,
    run: %Run{id: run_id},
    os_process: os_process
  } do
    test_pid = self()
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    stub(Git, :up_to_date_with?, fn _path, _base -> false end)
    expect(Git, :merge_default_branch, fn _scope, _task -> {:conflicts, ["lib/a.ex"]} end)

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:resolving, argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :merging} = Pipeline.end_turn_and_merge(task, os_process)
    assert_receive {:run_changed, ^run_id}, 5_000

    assert_received {:resolving, argv}
    assert Enum.any?(argv, &(&1 =~ "lib/a.ex"))
    assert %Task{is_updating_branch: true} = Repo.reload!(task)
    assert %Run{status: :running} = Repo.get!(Run, run_id)
  end

  test "a conflict turn waiting for usage keeps the run in progress and the queued message behind it", %{
    task: task,
    run: %Run{id: run_id} = run,
    os_process: os_process
  } do
    {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Also rename the module"})
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    stub(Git, :up_to_date_with?, fn _path, _base -> false end)
    expect(Git, :merge_default_branch, fn _scope, _task -> {:conflicts, ["lib/a.ex"]} end)

    expect(Tools, :start_os_process, fn spawned, _argv ->
      {:ok, waiting} = Pipeline.update_run(spawned, %{status: :waiting_for_usage})
      {:ok, %OsProcess{run: waiting}}
    end)

    assert {:ok, :merging} = Pipeline.end_turn_and_merge(task, os_process)
    assert_receive {:run_changed, ^run_id}, 5_000

    # The settle broadcasts before it puts the queued message back, so the row is read until it has.
    eventually(fn ->
      assert %Run{status: :waiting_for_usage, stage_outcome: :in_progress, pending_chat: "Also rename the module"} =
               Repo.get!(Run, run_id)
    end)
  end

  test "a merge Rail could not make is recorded on the run", %{
    task: task,
    run: %Run{id: run_id},
    os_process: os_process
  } do
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    stub(Git, :up_to_date_with?, fn _path, _base -> false end)
    expect(Git, :merge_default_branch, fn _scope, _task -> {:error, "merge refused"} end)

    assert {:ok, :merging} = Pipeline.end_turn_and_merge(task, os_process)
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not merge the default branch in: merge refused"} = Repo.get!(Run, run_id)
  end

  test "a reason with no words of its own is spelled out on the run", %{
    task: task,
    run: %Run{id: run_id},
    os_process: os_process
  } do
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    stub(Git, :up_to_date_with?, fn _path, _base -> false end)
    expect(Git, :merge_default_branch, fn _scope, _task -> {:error, :locked} end)

    assert {:ok, :merging} = Pipeline.end_turn_and_merge(task, os_process)
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not merge the default branch in: :locked"} = Repo.get!(Run, run_id)
  end

  test "a request from a turn that has already ended is refused, merging nothing", %{
    task: task,
    os_process: os_process
  } do
    os_process |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
    reject(Tools, :stop_os_process, 3)
    reject(Git, :fetch_default_branch, 2)

    assert {:refused, "Refused, nothing merged again. This turn has already ended" <> _rest} =
             Pipeline.end_turn_and_merge(task, os_process)
  end

  test "a task past Engineer is refused with the turn still going", %{task: task, os_process: os_process} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing merged. The task is at Review, not Engineer" <> _rest} =
             Pipeline.end_turn_and_merge(task, os_process)
  end

  test "a merge already under way is refused", %{task: task, os_process: os_process} do
    {:ok, task} = Pipeline.update_task(task, %{is_updating_branch: true})
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing merged. A merge is already under way on this branch."} =
             Pipeline.end_turn_and_merge(task, os_process)
  end

  test "uncommitted changes are refused", %{task: task, repo: repo, os_process: os_process} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing merged. The worktree has uncommitted changes." <> _rest} =
             Pipeline.end_turn_and_merge(task, os_process)
  end

  test "a branch already up to date is refused", %{task: task, os_process: os_process} do
    stub(Git, :fetch_default_branch, fn _project, _path -> :ok end)
    expect(Git, :up_to_date_with?, fn _path, "main" -> true end)
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing merged. This branch already has everything on origin/main."} =
             Pipeline.end_turn_and_merge(task, os_process)
  end

  test "a fetch that fails is Rail's failure, with the turn still going", %{task: task, os_process: os_process} do
    expect(Git, :fetch_default_branch, fn _project, _path -> {:error, "no network"} end)
    reject(Tools, :stop_os_process, 3)

    assert {:error, "no network"} = Pipeline.end_turn_and_merge(task, os_process)
  end
end
