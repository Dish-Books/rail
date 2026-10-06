defmodule RailWeb.SandboxesLiveTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  setup %{conn: conn, project: project} do
    id = System.unique_integer([:positive])

    # Anyone signed in reads the page, admin or not.
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_sandboxes_#{id}",
        login: "sandboxes_#{id}",
        name: "Lucas Stellet",
        email: "sandboxes_#{id}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})

    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    now = DateTime.utc_now()

    run_on = fn title ->
      issue =
        Repo.insert!(%Issue{
          project_id: project.id,
          external_id: "lin_sbx_#{System.unique_integer([:positive])}",
          identifier: "DISH-#{System.unique_integer([:positive])}",
          title: title,
          state: :backlog
        })

      task =
        %Task{}
        |> Task.changeset(
          %{
            issue_id: issue.id,
            stage: :engineer,
            worktree_name: "sbx-#{issue.id}",
            worktree_path: "/tmp/sbx",
            scratch_path: "/tmp/sbx"
          },
          project.id
        )
        |> Repo.insert!()

      {:ok, run} = Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :running, started_at: now})
      {run, issue}
    end

    sandbox = fn run, attrs ->
      Repo.insert!(
        struct(
          %OsProcess{
            run_id: run.id,
            task_id: run.task_id,
            stream_path: "/dev/null",
            status: :running,
            started_at: DateTime.shift(now, minute: -1),
            reserved_cpus: 1,
            reserved_memory_gb: 2,
            launch: Jason.encode!(%{"executable" => "/bin/true", "args" => [], "env" => %{}, "cwd" => "/tmp"})
          },
          attrs
        )
      )
    end

    {building, building_issue} = run_on.("Recipe costs update when a supplier invoice changes an ingredient price")
    {checking, _issue} = run_on.("Backends page shows each account's remaining usage")

    busy =
      sandbox.(building, %{
        runtime: :docker,
        container_id: "c-busy",
        reserved_cpus: 2,
        reserved_memory_gb: 4,
        started_at: DateTime.shift(now, minute: -31)
      })

    ci = sandbox.(checking, %{kind: :ci, command: "mix ci"})

    {waiting_run, waiting_issue} = run_on.("Issues list remembers its filters per project")
    # Turns that straddle a month are numbered by time, not by the day of the month.
    _first_turn = sandbox.(waiting_run, %{status: :finished, inserted_at: ~U[2026-09-30 23:59:00.000000Z]})

    next =
      sandbox.(waiting_run, %{
        inserted_at: ~U[2026-10-01 00:01:00.000000Z],
        status: :waiting_for_resources,
        reserved_cpus: 2,
        reserved_memory_gb: 4,
        queued_at: DateTime.shift(now, second: -252)
      })

    {setup_run, _issue} = run_on.("Linear comments sync edits made after posting")

    behind =
      sandbox.(setup_run, %{kind: :setup, status: :waiting_for_resources, queued_at: DateTime.shift(now, second: -48)})

    {ended_run, _issue} = run_on.("Supplier credit notes reduce the invoice total")
    ended = &sandbox.(ended_run, Map.merge(%{status: :finished, ended_at: DateTime.shift(now, minute: -10)}, &1))
    finished = ended.(%{ended_reason: :finished})
    killed = ended.(%{ended_reason: :out_of_memory, reserved_cpus: 2, reserved_memory_gb: 4})
    stopped = ended.(%{ended_reason: :stopped, stopped_by_id: user.id})
    handed_over = ended.(%{ended_reason: :handed_over})
    timed_out = ended.(%{kind: :ci, ended_reason: :timed_out})
    killed_otherwise = ended.(%{ended_reason: :killed})
    never_started = ended.(%{ended_reason: :failed_to_start})
    _long_ago = ended.(%{ended_reason: :finished, ended_at: DateTime.shift(now, hour: -2)})

    Req.Test.stub(Docker, fn
      %{request_path: "/containers/c-busy/stats"} = conn ->
        Req.Test.json(conn, %{
          "cpu_stats" => %{"cpu_usage" => %{"total_usage" => 1_900}, "system_cpu_usage" => 16_000, "online_cpus" => 16},
          "precpu_stats" => %{"cpu_usage" => %{"total_usage" => 0}, "system_cpu_usage" => 0},
          "memory_stats" => %{"usage" => div(29 * 1024 ** 3, 10), "stats" => %{}}
        })
    end)

    %{
      conn: log_in_user(conn, user),
      user: user,
      engineer: engineer,
      run_on: run_on,
      sandbox: sandbox,
      now: now,
      building_issue: building_issue,
      waiting_issue: waiting_issue,
      busy: busy,
      ci: ci,
      next: next,
      behind: behind,
      finished: finished,
      killed: killed,
      stopped: stopped,
      handed_over: handed_over,
      timed_out: timed_out,
      killed_otherwise: killed_otherwise,
      never_started: never_started
    }
  end

  test "a turn whose issue Linear deletes leaves an open page, and the page still loads", %{
    conn: conn,
    project: project,
    run_on: run_on,
    sandbox: sandbox
  } do
    {run, issue} = run_on.("Deleted in Linear mid-turn")
    %OsProcess{id: sandbox_id} = sandbox.(run, %{})
    {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

    {:ok, view, _html} = live(conn, ~p"/sandboxes")
    assert has_element?(view, "#running-#{sandbox_id}")

    assert {:ok, %Issue{}} =
             Rail.Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "remove",
               "data" => %{"id" => issue.external_id}
             })

    refute has_element?(view, "#running-#{sandbox_id}")
    refute has_element?(view, "#ended-#{sandbox_id}")

    {:ok, reloaded, _html} = live(conn, ~p"/sandboxes")
    refute has_element?(reloaded, "#ended-#{sandbox_id}")
  end

  test "is a destination of its own, and says what a sandbox is", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    assert has_element?(view, "#nav-sandboxes[data-active='true']")
    assert has_element?(view, "#section-title", "Sandboxes")

    assert has_element?(
             view,
             "#sandboxes-intro",
             "Every agent turn, worktree setup and CI command runs in its own sandbox on this machine, holding what its role reserves."
           )
  end

  test "says how much of the machine is reserved, what runs, and what waits for what", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    assert has_element?(view, "#stat-cpus-reserved", "3")
    assert has_element?(view, "#stat-cpus-reserved", "of 4 · 1 free")
    assert has_element?(view, "#stat-memory-reserved", "6 GB")
    assert has_element?(view, "#stat-memory-reserved", "of 8 · 2 GB free")
    assert has_element?(view, "#stat-running", "1 agent turn · 0 setup · 1 CI")
    assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "2")
    assert has_element?(view, "#stat-waiting", "oldest 4m")
    assert has_element?(view, "#stat-waiting", "Short on CPUs and memory.")
  end

  test "lists the line oldest first, with what each needs and is short of", %{
    conn: conn,
    next: next,
    behind: behind,
    waiting_issue: waiting_issue
  } do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    assert has_element?(view, "#waiting-sandboxes-title", "Waiting for resources · oldest first")
    assert has_element?(view, "#waiting-#{next.id} [data-qa='line']", "1st")
    assert has_element?(view, "#waiting-#{next.id}", waiting_issue.identifier)
    assert has_element?(view, "#waiting-#{next.id}", "Issues list remembers its filters per project")
    assert has_element?(view, "#waiting-#{next.id} [data-qa='for']", "Turn 2")
    assert has_element?(view, "#waiting-#{next.id} [data-qa='needs']", "2 CPUs · 4 GB")
    assert has_element?(view, "#waiting-#{next.id} [data-qa='short-of']", "1 CPU · 2 GB")

    # It would fit, but waits behind the one ahead of it.
    assert has_element?(view, "#waiting-#{behind.id} [data-qa='line']", "2nd")
    assert has_element?(view, "#waiting-#{behind.id} [data-qa='for']", "Setup")
    assert has_element?(view, "#waiting-#{behind.id} [data-qa='short-of']", "—")
  end

  test "lists what runs and what it uses of its reservation", %{
    conn: conn,
    busy: busy,
    ci: ci,
    building_issue: building_issue
  } do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    assert has_element?(view, "#running-sandboxes-title", "Running · 2")
    assert has_element?(view, "#running-#{busy.id}", building_issue.identifier)
    assert has_element?(view, "#running-#{busy.id} [data-qa='for']", "Turn 1")
    refute has_element?(view, "#running-sandboxes thead", "Reserved")
    refute has_element?(view, "#running-#{busy.id} [data-qa='reserved']")
    assert has_element?(view, "#running-#{busy.id} [data-qa='running-for']", "31m")

    assert render_async(view) =~ "1.9"

    assert has_element?(view, "#running-#{busy.id} [data-qa='cpu-in-use']", "of 2 CPU · near limit")
    assert has_element?(view, "#running-#{busy.id} [data-qa='memory-in-use']", "2.9")
    assert has_element?(view, "#running-#{busy.id} [data-qa='memory-in-use']", "of 4 GB")

    # A sandbox beside Rail has no reading to show.
    assert has_element?(view, "#running-#{ci.id} [data-qa='for']", "CI")
    assert has_element?(view, "#running-#{ci.id} [data-qa='cpu-in-use']", "—")
  end

  test "lists what ended in the last hour, and how", %{
    conn: conn,
    finished: finished,
    killed: killed,
    stopped: stopped,
    handed_over: handed_over,
    timed_out: timed_out,
    killed_otherwise: killed_otherwise,
    never_started: never_started
  } do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    assert has_element?(view, "#ended-#{finished.id} [data-qa='ended-how']", "Finished")
    assert has_element?(view, "#ended-#{killed.id} [data-qa='ended-how']", "Killed · used more than its 4 GB")
    refute has_element?(view, "#ended-sandboxes thead", "Freed")
    refute has_element?(view, "#ended-#{killed.id} [data-qa='freed']")
    assert has_element?(view, "#ended-#{stopped.id} [data-qa='ended-how']", "Stopped by Lucas Stellet")
    # An engineer turn ended by `commit` finished; nobody stopped it.
    assert has_element?(view, "#ended-#{handed_over.id} [data-qa='ended-how']", "Finished")
    assert has_element?(view, "#ended-#{timed_out.id} [data-qa='ended-how']", "Timed out")
    assert has_element?(view, "#ended-#{killed_otherwise.id} [data-qa='ended-how']", "Killed")
    assert has_element?(view, "#ended-#{never_started.id} [data-qa='ended-how']", "Could not start")
    assert view |> element("#ended-sandboxes tbody") |> render() |> String.split("<tr") |> length() == 8
  end

  test "stopping a run from the line takes it out, and records who stopped it", %{
    conn: conn,
    next: next,
    user: %{id: user_id}
  } do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    view |> element("#waiting-#{next.id} button", "Stop") |> render_click()

    refute has_element?(view, "#waiting-#{next.id}")
    assert {:ok, %OsProcess{ended_reason: :stopped, stopped_by_id: ^user_id}} = Tools.get_os_process(next.id)
  end

  test "another project's sandboxes count toward the machine but show no row, and cannot be stopped", %{
    conn: conn,
    engineer: engineer,
    sandbox: sandbox,
    now: now,
    next: next,
    behind: behind
  } do
    {:ok, hidden_project} =
      Projects.create_project(system_scope(), %{
        name: "Hidden Sandboxes",
        github_repo: "example/hidden-sandboxes",
        github_installation_id: 558,
        linear_team_key: "HSB",
        default_branch: "main",
        clone_path: "/tmp/hidden-sandboxes"
      })

    issue =
      Repo.insert!(%Issue{
        project_id: hidden_project.id,
        external_id: "lin_sbx_hidden",
        identifier: "HSB-1",
        title: "A secret sandbox",
        state: :backlog
      })

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "sbx-hidden",
          worktree_path: "/tmp/sbx",
          scratch_path: "/tmp/sbx"
        },
        hidden_project.id
      )
      |> Repo.insert!()

    {:ok, run} = Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :running, started_at: now})
    running = sandbox.(run, %{})
    waiting = sandbox.(run, %{status: :waiting_for_resources, queued_at: DateTime.shift(now, minute: -10)})
    ended = sandbox.(run, %{status: :finished, ended_reason: :finished, ended_at: DateTime.shift(now, minute: -5)})

    {:ok, view, html} = live(conn, ~p"/sandboxes")

    assert has_element?(view, "#stat-running", "2 agent turns · 0 setup · 1 CI")
    assert has_element?(view, "#stat-waiting [data-qa='stat-value']", "3")
    assert has_element?(view, "#running-sandboxes-title", "Running · 2")

    refute has_element?(view, "#running-#{running.id}")
    refute has_element?(view, "#waiting-#{waiting.id}")
    refute has_element?(view, "#ended-#{ended.id}")

    refute html =~ "HSB-1"
    refute html =~ "A secret sandbox"

    # A row keeps its place in the whole machine's line.
    assert has_element?(view, "#waiting-#{next.id} [data-qa='line']", "2nd")
    assert has_element?(view, "#waiting-#{behind.id} [data-qa='line']", "3rd")

    render_hook(view, "stop", %{"run_id" => run.id})
    assert {:ok, %OsProcess{status: :running}} = Tools.get_os_process(running.id)

    {:ok, admin} =
      Users.register_oauth_user(%{github_id: "gh_sandboxes_admin", login: "sbx_admin", email: "sbx@x.com", admin: true})

    {:ok, admin_view, _html} = live(log_in_user(conn, admin), ~p"/sandboxes")

    assert has_element?(admin_view, "#running-#{running.id}", "HSB-1")
    assert has_element?(admin_view, "#waiting-#{waiting.id} [data-qa='line']", "1st")
    assert has_element?(admin_view, "#ended-#{ended.id}")
  end

  test "follows the line as it moves", %{conn: conn, behind: behind} do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    {:ok, _stopped} = Tools.stop_os_process(system_scope(), behind)
    send(view.pid, :sandboxes_changed)

    refute has_element?(view, "#waiting-#{behind.id}")
  end

  test "a usage read that fails leaves the page up, with no reading, and is tried again", %{conn: conn, busy: busy} do
    stub(Tools, :list_sandbox_usage, fn -> raise "Docker answered with something unreadable" end)

    {:ok, view, _html} = live(conn, ~p"/sandboxes")
    render_async(view)

    assert has_element?(view, "#running-#{busy.id} [data-qa='cpu-in-use']", "—")

    stub(Tools, :list_sandbox_usage, fn -> %{busy.id => %{cpus: 0.5, memory_gb: 1.0}} end)
    send(view.pid, :read_usage)

    assert render_async(view) =~ "0.5"
  end

  test "reads usage again on its own clock", %{conn: conn, busy: busy} do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")
    assert render_async(view) =~ "1.9"

    send(view.pid, :read_usage)

    assert render_async(view) =~ "1.9"
    assert has_element?(view, "#running-#{busy.id} [data-qa='cpu-in-use']", "1.9")
  end

  test "says so when the machine's capacity cannot be read", %{conn: conn, next: next} do
    stub(Tools, :get_sandbox_capacity, fn -> {:error, :econnrefused} end)

    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    assert has_element?(view, "#sandbox-capacity-unknown")
    refute has_element?(view, "#sandbox-stats")
    assert has_element?(view, "#waiting-#{next.id} [data-qa='short-of']", "—")
  end

  test "names the one resource a run is short of", %{conn: conn, next: next} do
    {:ok, view, _html} = live(conn, ~p"/sandboxes")

    next = next |> Ecto.Changeset.change(reserved_memory_gb: 2) |> Repo.update!()
    send(view.pid, :sandboxes_changed)
    assert has_element?(view, "#waiting-#{next.id} [data-qa='short-of']", "1 CPU")

    next |> Ecto.Changeset.change(reserved_cpus: 1, reserved_memory_gb: 4) |> Repo.update!()
    send(view.pid, :sandboxes_changed)
    assert has_element?(view, "#waiting-#{next.id} [data-qa='short-of']", "2 GB")
  end
end
