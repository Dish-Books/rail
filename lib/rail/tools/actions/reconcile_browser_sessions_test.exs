defmodule Rail.Tools.Actions.ReconcileBrowserSessionsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.BrowserRegistry
  alias Rail.Tools.Schemas.BrowserSession

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rcb_1", "identifier" => "RCB-1", "title" => "Reconcile Browsers"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Reconcile Browsers"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # No test here has a Chrome to ask, and one a browser test left up would answer for it.
    stub(Tools, :list_browser_contexts, fn -> :unknown end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    running = fn ->
      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

      run
    end

    %{task: task, project: project, running: running}
  end

  # The shared Chrome outlives everything, so a tab the task no longer needs is
  # one somebody has to close - and it is closed whatever holds it.
  test "closes every named tab of a task that has left Review", %{task: task} do
    {:ok, %BrowserSession{id: qa}} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "qa", status: :running, started_at: DateTime.utc_now()})
      |> Repo.insert()

    {:ok, %BrowserSession{id: explorer}} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        name: "explorer 2",
        status: :running,
        started_at: DateTime.shift(DateTime.utc_now(), second: 1)
      })
      |> Repo.insert()

    task |> Ecto.Changeset.change(stage: :merged) |> Repo.update!()

    assert [
             %BrowserSession{id: ^qa, status: :finished, finished_at: %DateTime{}},
             %BrowserSession{id: ^explorer, status: :finished, finished_at: %DateTime{}}
           ] = Tools.reconcile_browser_sessions()
  end

  # Only one live session is allowed per task, so a row nobody settled is what
  # stops that task ever being given another browser.
  test "a closed session lets its task have a browser again", %{task: task} do
    {:ok, _orphan} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "qa", status: :running})
      |> Repo.insert()

    task |> Ecto.Changeset.change(stage: :engineer) |> Repo.update!()

    assert [%BrowserSession{}] = Tools.reconcile_browser_sessions()

    assert {:ok, _room_now} =
             %BrowserSession{}
             |> BrowserSession.changeset(%{task_id: task.id, name: "qa", status: :starting})
             |> Repo.insert()
  end

  # Rail restarted in the middle of a round. The tab is still open in the shared
  # Chrome, and the panel and the problems it collects are what reconnecting gets
  # back without waiting for the agent to call.
  test "reconnects to the tab of a Review lead run that is running", %{task: task, running: running} do
    {:ok, _held} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        name: "qa",
        status: :running,
        browser_context_id: "ctx",
        target_id: "tgt"
      })
      |> Repo.insert()

    _run = running.()

    # Only the tab the row names: a blank one opened in its place would be handed to an agent mid-check.
    expect(Tools, :start_browser_session, fn %{id: id}, "qa", [existing: true] when id == task.id -> {:ok, self()} end)

    assert Tools.reconcile_browser_sessions() == []
  end

  # Between rounds the task waits on a human at Review, for minutes or for days, and
  # every tab kept for it is memory the running passes' tabs share. The next round signs in again.
  test "closes the tabs of a task at Review whose run is waiting on a human", %{task: task} do
    {:ok, %BrowserSession{id: waiting}} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "explorer-1", status: :running})
      |> Repo.insert()

    reject(Tools, :start_browser_session, 3)

    assert [%BrowserSession{id: ^waiting, status: :finished, ended_reason: :closed}] = Tools.reconcile_browser_sessions()
  end

  # A task cleaned up keeps the stage it stopped at, so its stage says nothing about whether it wants a browser.
  test "closes the tabs of a task that was cleaned up while still at Review", %{task: task, running: running} do
    {:ok, %BrowserSession{id: left}} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "demo", status: :running})
      |> Repo.insert()

    _run = running.()
    task |> Ecto.Changeset.change(cleaned_up_at: DateTime.utc_now()) |> Repo.update!()

    assert [%BrowserSession{id: ^left, status: :finished}] = Tools.reconcile_browser_sessions()
  end

  # Chrome restarted under a running pass: every context it had is gone, and the row
  # says so, which is what tells the agent when it asks for its browser again.
  test "settles a session whose context Chrome no longer has as lost", %{task: task, running: running} do
    {:ok, %BrowserSession{id: lost}} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "explorer-1", status: :running, browser_context_id: "gone"})
      |> Repo.insert()

    {:ok, _kept} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        name: "explorer-2",
        status: :running,
        browser_context_id: "here",
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    _run = running.()
    stub(Tools, :list_browser_contexts, fn -> {:ok, MapSet.new(["here"])} end)
    expect(Tools, :start_browser_session, fn _task, "explorer-2", [existing: true] -> {:ok, self()} end)
    reject(Tools, :stop_browser_session, 1)

    assert [%BrowserSession{id: ^lost, status: :finished, ended_reason: :browser_gone, finished_at: %DateTime{}}] =
             Tools.reconcile_browser_sessions()
  end

  # The session watching a tab that went with Chrome has nothing left to watch.
  test "a lost session's process is shut down with its row", %{task: task, running: running} do
    {:ok, _lost} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "qa", status: :running, browser_context_id: "gone"})
      |> Repo.insert()

    _run = running.()
    {:ok, holder} = Agent.start(fn -> Registry.register(BrowserRegistry, {task.id, "qa"}, nil) end)
    stub(Tools, :list_browser_contexts, fn -> {:ok, MapSet.new()} end)

    assert [%BrowserSession{ended_reason: :browser_gone}] = Tools.reconcile_browser_sessions()
    refute Process.alive?(holder)
  end

  # A session with a process is that process's while its task still wants it.
  test "leaves a session something is still driving", %{task: task, running: running} do
    {:ok, _held} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "qa", status: :running})
      |> Repo.insert()

    _run = running.()

    holder =
      spawn(fn ->
        {:ok, _registered} = Registry.register(BrowserRegistry, {task.id, "qa"}, nil)
        receive do: (:release -> :ok)
      end)

    eventually(fn -> assert Registry.lookup(BrowserRegistry, {task.id, "qa"}) != [] end)
    reject(Tools, :start_browser_session, 3)

    assert Tools.reconcile_browser_sessions() == []

    send(holder, :release)
  end

  test "a session already finished is left alone", %{task: task} do
    {:ok, _done} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        name: "qa",
        status: :finished,
        finished_at: DateTime.utc_now()
      })
      |> Repo.insert()

    task |> Ecto.Changeset.change(stage: :merged) |> Repo.update!()
    reject(Tools, :stop_browser_session, 1)

    assert Tools.reconcile_browser_sessions() == []
  end
end
