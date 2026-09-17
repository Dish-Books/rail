defmodule Rail.Pipeline.Utils.DispatchMessageTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.DispatchMessage

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Dispatch Message Project",
        github_repo: "org/dispatch-message",
        github_installation_id: 47_001,
        linear_workspace: %{
          name: "Dispatch Message Workspace",
          external_id: "lin_ws_dispatch_message",
          token: "lin_api_token_dispatch_message",
          webhook_secret: "whsec_dispatch_message"
        },
        linear_team_key: "DSP",
        default_branch: "main",
        clone_path: "/tmp/repos/dispatch-message",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :product,
        name: "product role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the product agent."
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_dispatch_message_1",
              "identifier" => "DSP-1",
              "title" => "Dispatch Message Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Dispatch Message Issue"})
    {:ok, task} = Pipeline.create_task(issue, :product)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_dispatch_message",
        pending_chat: "Please also add a test",
        started_at: DateTime.utc_now()
      })

    %{run: run, run_id: run_id}
  end

  test "sends the queued message and takes it off the run", %{run: run, run_id: run_id} do
    expect(Tools, :start_os_process, fn spawned, argv ->
      assert Enum.any?(argv, &(&1 =~ "Please also add a test"))
      {:ok, %OsProcess{run: spawned}}
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert {:ok, %OsProcess{}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: nil, status: :running} = Repo.reload!(run)
    assert_received {:run_changed, ^run_id}
  end

  test "a message that fails to spawn goes back on the run", %{run: run, run_id: run_id} do
    expect(Tools, :start_os_process, fn spawned, _argv -> {:error, {:spawn_failed, :enoent, spawned}} end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")

    assert {:error, {:spawn_failed, :enoent}} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
    assert_received {:run_changed, ^run_id}
    assert [%RunEvent{line: "[rail] That message was not delivered: " <> _reason}] = Repo.all(RunEvent)
  end

  test "a message held back by disabled dispatch stays queued", %{run: run} do
    expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

    assert {:error, :dispatch_disabled} = dispatch_message(run, async: false)
    assert %Run{pending_chat: "Please also add a test"} = Repo.reload!(run)
  end

  test "a run that is gone has nothing to dispatch", %{run: run} do
    Repo.delete!(run)

    assert {:error, :invalid_state} = dispatch_message(run, async: false)
  end
end
