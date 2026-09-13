defmodule Rail.Pipeline.Actions.StopAndSendMessageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Runs
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, backend} = Rail.Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Stop And Send Project",
        github_repo: "org/stop-and-send",
        github_installation_id: 42_002,
        linear_workspace: %{
          name: "Stop And Send Workspace",
          external_id: "lin_ws_stop_and_send",
          token: "lin_api_token_stop_and_send",
          webhook_secret: "whsec_stop_and_send"
        },
        linear_team_id: "team_stop_and_send",
        linear_team_key: "SAS",
        default_branch: "main",
        clone_path: "/tmp/repos/stop-and-send",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_stop_and_send_1",
      "identifier" => "SAS-1",
      "title" => "Stop And Send Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Stop And Send Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    working = fn attrs ->
      {:ok, run} =
        Runs.create_run(
          Map.merge(
            %{
              task_id: task.id,
              role_id: role.id,
              status: :running,
              conversation_id: "sess_stop_and_send",
              started_at: DateTime.utc_now()
            },
            attrs
          )
        )

      run
    end

    %{project: project, task: task, role: role, working: working}
  end

  test "the queued message goes out in place of the turn it interrupts", %{working: working} do
    run = working.(%{pending_chat: "Please add a test"})

    stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.stop_and_send_message(run)
  end

  test "there is nothing to send now when nothing was queued", %{working: working} do
    run = working.(%{})

    assert {:error, :nothing_queued} = Pipeline.stop_and_send_message(run)
  end
end
