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

    %{task: task, project: project}
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
  test "reconnects to the tab of a Review lead run that is running", %{task: task, project: project} do
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

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    expect(Tools, :start_browser_session, fn %{id: id}, "qa", [] when id == task.id -> {:ok, self()} end)

    assert Tools.reconcile_browser_sessions() == []
  end

  # Between rounds the task waits on a human at Review, and the next round
  # attaches when it runs; until then there is nothing to watch.
  test "keeps the tab of a task at Review between rounds for the next one", %{task: task} do
    {:ok, _waiting} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        name: "qa",
        status: :running,
        browser_context_id: "ctx",
        target_id: "tgt"
      })
      |> Repo.insert()

    reject(Tools, :start_browser_session, 3)
    reject(Tools, :stop_browser_session, 1)

    assert Tools.reconcile_browser_sessions() == []
  end

  # A session with a process is that process's while its task still wants it.
  test "leaves a session something is still driving", %{task: task} do
    {:ok, _held} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, name: "qa", status: :running})
      |> Repo.insert()

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
