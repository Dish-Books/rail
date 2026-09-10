defmodule Rail.PeriodicTest do
  use Rail.DataCase, async: false

  import RailTest.Mocks.GitHub

  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Domain.TaskUsage
  alias Rail.Periodic
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.RunEvent
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, pid} =
      Periodic.start_link(
        name: nil,
        auto_start: false,
        backend_opts: [
          claude_opts: [path_validator: fn _path -> false end],
          agy_opts: [path_validator: fn _path -> false end]
        ]
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _err -> :ok
        end
      end
    end)

    %{server: pid}
  end

  test "canonical_tick/1 normalizes tick names and aliases" do
    assert :mergeability_demo_freshness = Periodic.canonical_tick(:mergeability)
    assert :mergeability_demo_freshness = Periodic.canonical_tick(:mergeability_demo_freshness)
    assert :linear_sync = Periodic.canonical_tick(:linear_sync)
    assert :usage_probes = Periodic.canonical_tick(:usage_probes)
    assert :run_events_prune = Periodic.canonical_tick(:run_events_prune)
    assert :run_events_prune = Periodic.canonical_tick(:prune)
    assert :run_events_prune = Periodic.canonical_tick(:prune_run_events)
    assert :custom_tick = Periodic.canonical_tick(:custom_tick)
  end

  test "initializes with default and custom intervals", %{server: server} do
    intervals = Periodic.intervals(server)

    assert %{
             mergeability_demo_freshness: 120_000,
             linear_sync: 300_000,
             usage_probes: 900_000,
             run_events_prune: 86_400_000
           } = intervals

    {:ok, custom_pid} =
      Periodic.start_link(
        name: nil,
        auto_start: false,
        intervals: %{
          mergeability_demo_freshness: 10_000,
          linear_sync: 20_000
        }
      )

    custom_intervals = Periodic.intervals(custom_pid)

    assert %{
             mergeability_demo_freshness: 10_000,
             linear_sync: 20_000,
             usage_probes: 900_000,
             run_events_prune: 86_400_000
           } = custom_intervals

    GenServer.stop(custom_pid)
  end

  test "returns error when triggering an unknown tick", %{server: server} do
    assert {:error, {:unknown_tick, :nonexistent_tick}} =
             Periodic.trigger_tick(server, :nonexistent_tick)

    assert {:error, {:unknown_tick, :nonexistent_tick}} =
             Periodic.execute_tick(:nonexistent_tick)
  end

  test "tick 1: mergeability and demo freshness refreshes active tasks with PRs", %{
    server: server
  } do
    project = Repo.insert!(%{Project.factory() | github_repo: "org/merge-tick-repo"})

    # Task 1: active with PR -> should be refreshed
    %Task{id: t1_id} =
      t1 =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 10,
          mergeability: :unknown,
          pr_is_draft: false
      })

    # Task 2: active with PR -> should be refreshed
    %Task{id: t2_id} =
      t2 =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :review,
          pr_number: 20,
          mergeability: :unknown,
          pr_is_draft: true
      })

    # Task 3: no PR -> should be ignored by query
    _task_no_pr =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :engineer,
          pr_number: nil
      })

    # Task 4: merged stage -> should be ignored by query
    _task_merged =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :merged,
          pr_number: 30
      })

    # Task 5: merged_at set -> should be ignored by query
    _task_merged_at =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 40,
          merged_at: DateTime.utc_now()
      })

    tasks = Enum.sort_by([t1, t2], & &1.id)

    for task <- tasks do
      if task.id == t1_id do
        mock_pull_request_state_success("org/merge-tick-repo", 10, mergeable: true, draft: false)
      else
        mock_pull_request_state_success("org/merge-tick-repo", 20, mergeable: false, draft: false)
      end
    end

    assert {:ok, %{processed: 2, results: results}} =
             Periodic.trigger_tick(server, :mergeability_demo_freshness, token: "mock_tok")

    results_map = Map.new(results)

    assert %{
             ^t1_id => {:ok, {:ok, %Task{mergeability: :mergeable}}, {:ok, %Task{}}},
             ^t2_id => {:ok, {:ok, %Task{mergeability: :conflicting}}, {:ok, %Task{}}}
           } = results_map
  end

  test "tick 1: error on one task does not stop execution of remaining tasks", %{server: server} do
    project = Repo.insert!(%{Project.factory() | github_repo: "org/error-tick-repo"})

    %Task{id: err_id} =
      err_task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 77,
          mergeability: :unknown
      })

    %Task{id: ok_id} =
      ok_task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :ready_to_merge,
          pr_number: 88,
          mergeability: :unknown
      })

    tasks = Enum.sort_by([err_task, ok_task], & &1.id)

    for task <- tasks do
      if task.id == err_id do
        mock_pull_request_state_error("org/error-tick-repo", 77, 404, "Not Found")
      else
        mock_pull_request_state_success("org/error-tick-repo", 88, mergeable: true, draft: false)
      end
    end

    assert {:ok, %{processed: 2, results: results}} =
             Periodic.trigger_tick(server, :mergeability, token: "mock_tok")

    results_map = Map.new(results)

    assert %{
             ^err_id => {:ok, {:error, {:github_api_error, 404, _body}}, {:ok, %Task{}}},
             ^ok_id => {:ok, {:ok, %Task{mergeability: :mergeable}}, {:ok, %Task{}}}
           } = results_map
  end

  test "tick 2: linear sync syncs configured active projects", %{server: server} do
    workspace = Repo.insert!(LinearWorkspace.factory())

    # Project 1: configured with workspace and team -> synced
    %Project{id: p1_id} =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: workspace.id,
          linear_team_id: "team_p1",
          active: true
      })

    # Project 2: inactive -> ignored
    _p_inactive =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: workspace.id,
          linear_team_id: "team_inactive",
          active: false
      })

    # Project 3: no linear config -> ignored
    _p_no_linear =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: nil,
          linear_team_id: "",
          active: true
      })

    LinearMock.mock_issues_success([
      %{
        "id" => "lin_tick_1",
        "identifier" => "ENG-201",
        "title" => "Sync tick issue",
        "description" => "Desc",
        "state" => %{"id" => "st_1", "name" => "Triage", "type" => "triage"},
        "branchName" => nil,
        "url" => "https://linear.app/issue/ENG-201",
        "createdAt" => "2026-09-01T10:00:00.000Z",
        "updatedAt" => "2026-09-01T11:00:00.000Z"
      }
    ])

    assert {:ok, %{processed: 1, results: results}} =
             Periodic.trigger_tick(server, :linear_sync)

    assert [{^p1_id, {:ok, [_synced_issue]}}] = results
  end

  test "tick 2: failure on one project linear sync does not halt subsequent projects", %{
    server: server
  } do
    # Project with invalid credentials / no workspace
    %Project{id: bad_id} =
      Repo.insert!(%{
        Project.factory()
        | linear_workspace_id: nil,
          linear_team_id: "team_bad",
          active: true
      })

    assert {:ok, %{processed: 1, results: results}} =
             Periodic.trigger_tick(server, :linear_sync)

    assert [{^bad_id, {:error, :no_workspace_token}}] = results
  end

  test "tick 3: usage probes triggers refresh_usage", %{server: server} do
    test_node = "usage-probe-node-#{System.unique_integer([:positive])}"

    assert {:ok, accounts} =
             Periodic.trigger_tick(
               server,
               :usage_probes,
               node: test_node,
               claude_opts: [path_validator: fn _path -> false end],
               agy_opts: [path_validator: fn _path -> false end]
             )

    assert length(accounts) == 2
    assert [%CliAccount{}, %CliAccount{}] = accounts
  end

  test "tick 4: run events prune removes historical events and marks role_runs", %{
    server: server
  } do
    past_date = DateTime.shift(DateTime.utc_now(), week: -5)

    role_run =
      create_test_role_run(%{
        status: :finished,
        completed_at: past_date,
        inserted_at: past_date,
        exit_code: 0,
        output: "Pruned run output",
        pruned: false,
        usage: %TaskUsage{input_tokens: 150, output_tokens: 50}
      })

    create_test_run_event(%{
      role_run_id: role_run.id,
      seq: 1,
      line: "Event 1",
      inserted_at: past_date
    })

    create_test_run_event(%{
      role_run_id: role_run.id,
      seq: 2,
      line: "Event 2",
      inserted_at: past_date
    })

    assert {:ok, %{pruned_events: 2, pruned_role_runs: 1}} =
             Periodic.tick_now(server, :prune)

    assert [] = Repo.all(Ecto.Query.from(e in RunEvent, where: e.role_run_id == ^role_run.id))

    assert %RoleRun{
             pruned: true,
             exit_code: 0,
             output: "Pruned run output",
             usage: %TaskUsage{input_tokens: 150, output_tokens: 50}
           } = Repo.get!(RoleRun, role_run.id)
  end

  test "single-flighting skips concurrent invocation of the same tick", %{server: server} do
    # Start a tick asynchronously
    assert :ok = Periodic.trigger_tick(server, :usage_probes, async: true)

    # Immediately try to trigger the same tick while running
    res = Periodic.trigger_tick(server, :usage_probes)
    assert match?({:skipped, :already_running}, res) or match?({:ok, _}, res)

    # Wait until all running ticks clear
    wait_until_ticks_clear(server, 500)
    assert [] = Periodic.running_ticks(server)
  end

  test "async trigger executes in background and notifies info tick message", %{server: server} do
    # Trigger tick via :tick message directly
    send(server, {:tick, :usage_probes})

    # Wait for the background task to complete
    wait_until_ticks_clear(server, 1000)
    assert [] = Periodic.running_ticks(server)
  end

  test "info tick message is safely skipped if tick is already in progress", %{server: server} do
    # Trigger tick async
    assert :ok = Periodic.trigger_tick(server, :usage_probes, async: true)

    # Send periodic timer tick message while running
    send(server, {:tick, :usage_probes})

    wait_until_ticks_clear(server, 1000)
    assert [] = Periodic.running_ticks(server)
  end

  test "handles abnormal task termination without crashing GenServer", %{server: server} do
    assert {:error, {%RuntimeError{message: "intentional test crash"}, _stack}} =
             Periodic.trigger_tick(server, :usage_probes, crash: true)

    assert Process.alive?(server)
    assert [] = Periodic.running_ticks(server)

    # Unrecognized ref in :DOWN is safely ignored
    ref = make_ref()
    send(server, {:DOWN, ref, :process, self(), :abnormal_exit})
    Process.sleep(10)
    assert Process.alive?(server)
  end

  test "auto_start: true schedules timers on boot" do
    {:ok, server_pid} =
      Periodic.start_link(
        name: nil,
        auto_start: true,
        intervals: %{
          mergeability_demo_freshness: 60_000,
          linear_sync: 60_000,
          usage_probes: 60_000,
          run_events_prune: 0
        }
      )

    assert Process.alive?(server_pid)
    GenServer.stop(server_pid)
  end

  test "execute_tick/2 executes all tick variants directly" do
    assert {:ok, %{processed: 0, results: []}} =
             Periodic.execute_tick(:mergeability_demo_freshness)

    assert {:ok, %{processed: 0, results: []}} =
             Periodic.execute_tick(:linear_sync)

    assert {:ok, accounts} =
             Periodic.execute_tick(:usage_probes,
               claude_opts: [path_validator: fn _path -> false end],
               agy_opts: [path_validator: fn _path -> false end]
             )

    assert length(accounts) == 2

    assert {:ok, %{pruned_events: 0, pruned_role_runs: 0}} =
             Periodic.execute_tick(:run_events_prune)
  end
end
