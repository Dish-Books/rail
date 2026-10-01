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
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, project: project}
  end

  # The shared Chrome outlives everything, so a tab the task no longer needs is
  # one somebody has to close - and it is closed whatever holds it.
  test "closes the tab of a task that has left QA and demo", %{task: task} do
    {:ok, %BrowserSession{id: closed}} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, status: :running, started_at: DateTime.utc_now()})
      |> Repo.insert()

    task |> Ecto.Changeset.change(stage: :merged) |> Repo.update!()

    assert [%BrowserSession{id: ^closed, status: :finished, finished_at: %DateTime{}}] =
             Tools.reconcile_browser_sessions()
  end

  # Only one live session is allowed per task, so a row nobody settled is what
  # stops that task ever being given another browser.
  test "a closed session lets its task have a browser again", %{task: task} do
    {:ok, _orphan} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, status: :running})
      |> Repo.insert()

    task |> Ecto.Changeset.change(stage: :engineer) |> Repo.update!()

    assert [%BrowserSession{}] = Tools.reconcile_browser_sessions()

    assert {:ok, _room_now} =
             %BrowserSession{}
             |> BrowserSession.changeset(%{task_id: task.id, status: :starting})
             |> Repo.insert()
  end

  # Rail restarted in the middle of a pass. The tab is still open in the shared
  # Chrome, and the panel and the problems it collects are what reconnecting gets
  # back without waiting for the agent to call.
  test "reconnects to the tab of a pass that is running", %{task: task, project: project} do
    {:ok, _held} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, status: :running, browser_context_id: "ctx", target_id: "tgt"})
      |> Repo.insert()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :qa)

    {:ok, _run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    expect(Tools, :start_browser_session, fn %{id: id}, [] when id == task.id -> {:ok, self()} end)

    assert Tools.reconcile_browser_sessions() == []
  end

  # A pass waiting on a human attaches when it next runs; until then there is
  # nothing to watch.
  test "leaves the tab of a pass that is not running for its next run", %{task: task} do
    {:ok, _waiting} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, status: :running, browser_context_id: "ctx", target_id: "tgt"})
      |> Repo.insert()

    reject(Tools, :start_browser_session, 2)
    reject(Tools, :stop_browser_session, 1)

    assert Tools.reconcile_browser_sessions() == []
  end

  # A session with a process is that process's while its task still wants it.
  test "leaves a session something is still driving", %{task: task} do
    {:ok, _held} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, status: :running})
      |> Repo.insert()

    holder =
      spawn(fn ->
        {:ok, _registered} = Registry.register(BrowserRegistry, task.id, nil)
        receive do: (:release -> :ok)
      end)

    eventually(fn -> assert Registry.lookup(BrowserRegistry, task.id) != [] end)
    reject(Tools, :start_browser_session, 2)

    assert Tools.reconcile_browser_sessions() == []

    send(holder, :release)
  end

  test "a session already finished is left alone", %{task: task} do
    {:ok, _done} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        status: :finished,
        finished_at: DateTime.utc_now()
      })
      |> Repo.insert()

    task |> Ecto.Changeset.change(stage: :merged) |> Repo.update!()
    reject(Tools, :stop_browser_session, 1)

    assert Tools.reconcile_browser_sessions() == []
  end
end
