defmodule Rail.Tools.Actions.ReconcileBrowserSessionsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Tools
  alias Rail.Tools.BrowserRegistry
  alias Rail.Tools.Schemas.BrowserSession

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Reconcile Browsers Project",
        github_repo: "org/reconcile-browsers",
        github_installation_id: 47_040,
        linear_workspace: %{
          name: "Reconcile Browsers Workspace",
          external_id: "lin_ws_reconcile_browsers",
          token: "lin_api_token_reconcile_browsers",
          webhook_secret: "whsec_reconcile_browsers"
        },
        linear_team_key: "RCB",
        default_branch: "main",
        clone_path: "/tmp/repos/reconcile-browsers",
        linear_state_ids: %{"triage" => "st_triage"}
      })

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

    %{task: task}
  end

  # The machine went down, or the session was killed outright. Nothing ran
  # `terminate`, so the browser is still up and the row still says it is running.
  test "reaps a session nothing is driving", %{task: task} do
    profile = Path.join(System.tmp_dir!(), "rail-reconcile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(profile)

    {:ok, %BrowserSession{id: reaped}} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{
        task_id: task.id,
        status: :running,
        profile_path: profile,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert()

    assert [%BrowserSession{id: ^reaped, status: :finished, finished_at: %DateTime{}}] =
             Tools.reconcile_browser_sessions()

    refute File.exists?(profile)
  end

  # Only one live session is allowed per task, so a row nobody settled is what
  # stops that task ever being given another browser.
  test "a reaped session lets its task have a browser again", %{task: task} do
    {:ok, _orphan} =
      %BrowserSession{}
      |> BrowserSession.changeset(%{task_id: task.id, status: :running})
      |> Repo.insert()

    assert [%BrowserSession{}] = Tools.reconcile_browser_sessions()

    assert {:ok, _room_now} =
             %BrowserSession{}
             |> BrowserSession.changeset(%{task_id: task.id, status: :starting})
             |> Repo.insert()
  end

  # A session with a process is that process's to settle, alive or dead: it holds
  # the browser and it runs its own cleanup on the way out.
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

    assert Tools.reconcile_browser_sessions() == []
  end
end
