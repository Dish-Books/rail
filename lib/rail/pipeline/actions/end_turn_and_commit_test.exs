defmodule Rail.Pipeline.Actions.EndTurnAndCommitTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
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
            "issue" => %{"id" => "lin_etc_1", "identifier" => "ETC-1", "title" => "End Turn Commit"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "End Turn Commit"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_end_turn_commit",
        started_at: DateTime.utc_now()
      })

    {:ok, os_process} =
      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        stream_path: "/tmp/end_turn_commit/#{run.id}.ndjson",
        status: :running,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    Req.Test.stub(Rail.GitHub.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", _pulls} -> Req.Test.json(conn, [])
        {"POST", _pulls} -> conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"number" => 7, "draft" => true})
      end
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run.id}")

    %{task: task, run: run, repo: repo, os_process: os_process}
  end

  test "an accepted commit stops the turn, then commits under the agent's words and pushes", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: %OsProcess{id: os_process_id} = os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    test_pid = self()

    expect(Tools, :stop_os_process, fn _scope, %OsProcess{id: ^os_process_id}, opts ->
      assert opts[:ended_reason] == :handed_over
      send(test_pid, :stopped)
      {:ok, os_process}
    end)

    expect(Git, :push_branch, fn _scope, _task -> :ok end)

    assert {:ok, :committing} =
             Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature\n\nWhy it changed.")

    assert_received :stopped
    assert_receive {:run_changed, ^run_id}, 5_000

    assert git!(repo, ["log", "-1", "--pretty=%B"]) =~ ~r/\AETC-1: add the feature\n\nWhy it changed.\n\nTicket: ETC-1/
    assert %Run{status: :finished, stage_outcome: :done, error: nil} = Repo.get!(Run, run_id)
    refute File.exists?(Path.join(task.scratch_path, "commits"))
  end

  # The agent's CLI can send one call twice, the second while the first is still
  # ending the turn; the stop marks the row finished, as the real one does.
  test "the same call twice at once commits once, and the repeat is refused", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    expect(Tools, :stop_os_process, fn _scope, %OsProcess{} = stopping, _opts ->
      stopped = stopping |> OsProcess.changeset(%{status: :finished}) |> Repo.update!()
      {:ok, stopped}
    end)

    expect(Git, :push_branch, fn _scope, _task -> :ok end)

    calls =
      for _n <- 1..2, do: Elixir.Task.async(fn -> Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add it") end)

    results = Elixir.Task.await_many(calls)

    assert [{:ok, :committing}, {:refused, "Refused, nothing committed again. This turn has already ended" <> _rest}] =
             Enum.sort_by(results, &(elem(&1, 0) != :ok))

    assert_receive {:run_changed, ^run_id}, 5_000

    assert repo |> git!(["log", "--pretty=%s"]) |> String.split("\n") |> Enum.count(&(&1 == "ETC-1: add it")) == 1
    assert %Run{status: :finished, stage_outcome: :done, error: nil} = Repo.get!(Run, run_id)
  end

  test "a blank message is refused while the turn is still going", %{task: task, repo: repo, os_process: os_process} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. message: is required" <> _rest} =
             Pipeline.end_turn_and_commit(task, os_process, "  ")
  end

  test "a worktree with nothing changed is refused", %{task: task, os_process: os_process} do
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. Nothing in the worktree has changed." <> _rest} =
             Pipeline.end_turn_and_commit(task, os_process, "ETC-1: nothing")
  end

  test "a turn resolving a merge is refused, since that commit is Rail's", %{
    task: task,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, task} = Pipeline.update_task(task, %{is_updating_branch: true})
    reject(Tools, :stop_os_process, 3)

    assert {:refused, "Refused, nothing committed. This turn is resolving a merge" <> _rest} =
             Pipeline.end_turn_and_commit(task, os_process, "ETC-1: resolve")
  end

  test "after a CI failure, nothing changed runs CI again on the same commit", %{
    project: project,
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, _streak} = Pipeline.update_run(run, %{ci_failure_streak: 1})

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)
    reject(&Git.push_branch/2)

    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
      {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: rerun CI past a flaky test")
    assert_receive {:run_changed, ^run_id}, 5_000

    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "initial commit"
    assert %Run{status: :running, stage_outcome: :in_progress} = Repo.get!(Run, run_id)
  end

  test "on a project with CI, the commit starts CI on the new head and is not done until it passes", %{
    project: project,
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    head_before = String.trim(git!(repo, ["rev-parse", "HEAD"]))

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)
    reject(&Git.push_branch/2)

    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", opts ->
      refute opts[:head_sha] == head_before
      {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{status: :running, stage_outcome: :in_progress, error: nil} = Repo.get!(Run, run_id)
    refute Git.worktree_dirty?(repo)
  end

  test "CI that cannot get a credential is recorded on the run", %{
    project: project,
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:error, {:github_api_error, 404, %{}}} end)
    reject(Tools, :start_command_process, 4)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not commit the engineer's work: Could not start CI: " <> _reason} = Repo.get!(Run, run_id)
  end

  # Another run's sandbox holds all 4 CPUs the test machine has (config/test.exs).
  test "CI waiting in line for room keeps the run open and a queued message for after it", %{
    project: project,
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    {:ok, _project} = Projects.update_project(system_scope(), project, %{ci_command: "mise run ci"})
    {:ok, review_role} = Roles.get_role(project_id: project.id, stage: :review)

    {:ok, other} =
      Pipeline.create_run(%{task_id: task.id, role_id: review_role.id, status: :running, started_at: DateTime.utc_now()})

    Repo.insert!(%OsProcess{
      run_id: other.id,
      task_id: task.id,
      stream_path: "/dev/null",
      status: :running,
      started_at: DateTime.utc_now(),
      reserved_cpus: 4,
      reserved_memory_gb: 2
    })

    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Also tidy the tests"})
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :credential_env, fn _project -> {:ok, %{"RAIL_GIT_TOKEN" => "ghs_token"}} end)
    reject(Tools, :start_os_process, 2)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")

    # Joining the line says so on the run's topic too, so the settle is waited for.
    eventually(fn ->
      assert %Run{status: :waiting_for_resources, stage_outcome: :in_progress, pending_chat: "Also tidy the tests"} =
               Repo.get!(Run, run_id)
    end)
  end

  test "a push that fails is recorded on the run", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not commit the engineer's work: remote rejected", stage_outcome: :in_progress} =
             Repo.get!(Run, run_id)
  end

  # The agent is already stopped, so a crash must still reach the human, and the
  # message they queued must still go out.
  test "a commit that raises is recorded on the run and in the conversation", %{
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> raise "the remote hung up" end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not finish the engineer's turn: the remote hung up", stage_outcome: :in_progress} =
             Repo.get!(Run, run_id)

    assert "[rail] Could not finish the engineer's turn: the remote hung up" in Enum.map(
             Pipeline.list_run_events(run),
             & &1.line
           )
  end

  test "a commit that raises still sends a queued message, and the conversation keeps why", %{
    task: task,
    run: run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Also rename the filter"})
    test_pid = self()

    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> raise "the remote hung up" end)

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:dispatched, argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:dispatched, argv}, 5_000
    assert Enum.any?(argv, &(&1 =~ "Also rename the filter"))

    assert "[rail] Could not finish the engineer's turn: the remote hung up" in Enum.map(
             Pipeline.list_run_events(run),
             & &1.line
           )
  end

  # Git's refusals run to several lines, and a log line is one: the rest would read
  # as the agent's own words.
  test "a failure over several lines is said on one", %{
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote: GH006: Protected branch\nTo origin.git\n"} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:run_changed, ^run_id}, 5_000

    assert ["[rail] Could not commit the engineer's work: remote: GH006: Protected branch To origin.git"] =
             Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "a failure git gives no words for is spelled out on the run", %{
    task: task,
    run: %Run{id: run_id},
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :stop_os_process, fn _scope, _os_process, _opts -> {:ok, os_process} end)
    stub(Git, :commit_worktree, fn _scope, _task, _message -> {:error, :index_locked} end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:run_changed, ^run_id}, 5_000

    assert %Run{error: "Could not commit the engineer's work: :index_locked"} = Repo.get!(Run, run_id)
  end

  # The queue comes off the row before the stop, so the stopped turn's settle
  # cannot send it from under the commit, and it goes out once the run is idle.
  test "a message the human queued is held through the commit and sent after it", %{
    task: task,
    run: %Run{id: run_id} = run,
    repo: repo,
    os_process: os_process
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, _queued} = Pipeline.update_run(run, %{pending_chat: "Also rename the filter"})
    test_pid = self()

    expect(Tools, :stop_os_process, fn _scope, _os_process, _opts ->
      assert %Run{pending_chat: nil} = Repo.get!(Run, run_id)
      {:ok, os_process}
    end)

    stub(Git, :push_branch, fn _scope, _task -> :ok end)

    expect(Tools, :start_os_process, fn spawned, argv ->
      send(test_pid, {:dispatched, argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, :committing} = Pipeline.end_turn_and_commit(task, os_process, "ETC-1: add the feature")
    assert_receive {:dispatched, argv}, 5_000
    assert Enum.any?(argv, &(&1 =~ "Also rename the filter"))
  end
end
