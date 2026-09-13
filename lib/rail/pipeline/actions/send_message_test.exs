defmodule Rail.Pipeline.Actions.SendMessageTest do
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

    {:ok, workspace} =
      Projects.upsert_linear_workspace(scope, %{
        name: "Send Message Workspace",
        external_id: "lin_ws_send_message",
        token: "lin_api_token_send_message",
        webhook_secret: "whsec_send_message"
      })

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Send Message Project",
        github_repo: "org/send-message",
        github_installation_id: 41_001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_send_message",
        linear_team_key: "SND",
        default_branch: "main",
        clone_path: "/tmp/repos/send-message",
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
      "id" => "lin_send_message_1",
      "identifier" => "SND-1",
      "title" => "Send Message Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Send Message Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    idle = fn ->
      {:ok, run} =
        Runs.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          conversation_id: "sess_send_message",
          started_at: DateTime.utc_now()
        })

      run
    end

    %{project: project, task: task, role: role, idle: idle}
  end

  test "a message to an idle run goes out now", %{idle: idle} do
    run = idle.()

    stub(Runs, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_message(run, "Please add a test")
  end

  test "a message to a working run waits on it", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    assert {:ok, :queued, %Run{pending_chat: "Please add a test"}} =
             Pipeline.send_message(run, "Please add a test")
  end

  test "a second thought lands behind the first in the same turn", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    {:ok, :queued, run} = Pipeline.send_message(run, "First")
    assert {:ok, :queued, %Run{pending_chat: "First\n\nSecond"}} = Pipeline.send_message(run, "Second")
  end

  test "the human's words go into the log as they are typed", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    {:ok, :queued, run} = Pipeline.send_message(run, "One line\nAnother line")

    assert ["[human] One line", "[human] Another line"] = Enum.map(Runs.list_run_events(run), & &1.line)
  end

  test "a run holding no conversation cannot be messaged", %{task: task, role: role} do
    {:ok, run} =
      Runs.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, :chat_unavailable} = Pipeline.send_message(run, "Anyone there?")
  end

  test "an empty message is not a message", %{idle: idle} do
    run = idle.()

    assert {:error, :empty_message} = Pipeline.send_message(run, "   ")
    assert {:error, :empty_message} = Pipeline.send_message(run, nil)
  end

  test "a run that is gone cannot be messaged", %{idle: idle} do
    run = idle.()
    Repo.delete!(run)

    assert {:error, :not_found} = Pipeline.send_message(run, "Hello?")
  end
end
