defmodule Rail.Pipeline.Actions.SendMessageTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
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
            "issue" => %{
              "id" => "lin_send_message_1",
              "identifier" => "SND-1",
              "title" => "Send Message Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Send Message Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    idle = fn ->
      {:ok, run} =
        Pipeline.create_run(%{
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

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.send_message(system_scope(), run, "Please add a test")
  end

  test "a message to a working run waits on it", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    assert {:ok, :queued, %Run{pending_chat: "Please add a test"}} =
             Pipeline.send_message(system_scope(), run, "Please add a test")
  end

  test "a second thought lands behind the first in the same turn", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    {:ok, :queued, run} = Pipeline.send_message(system_scope(), run, "First")
    assert {:ok, :queued, %Run{pending_chat: "First\n\nSecond"}} = Pipeline.send_message(system_scope(), run, "Second")
  end

  # Everyone on the task reads the same conversation, so each line says who sent it.
  test "the human's words go into the log as they are typed, under who sent them", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()
    %{user: %{id: user_id}} = scope = user_scope()

    {:ok, :queued, run} = Pipeline.send_message(scope, run, "One line\nAnother line")

    assert Enum.map(Pipeline.list_run_events(run), & &1.line) ==
             ["[human:#{user_id}] One line", "[human:#{user_id}] Another line"]
  end

  test "a message from nobody in particular is logged as the human's", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    {:ok, :queued, run} = Pipeline.send_message(system_scope(), run, "One line")

    assert ["[human] One line"] = Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "a plan revision is logged as Rail's note, not a person's", %{idle: idle} do
    {:ok, run} = idle.() |> Run.changeset(%{status: :running}) |> Repo.update()

    assert {:ok, :queued, %Run{}} =
             Pipeline.send_message(system_scope(), run, "The plan changed.\nIn full:", from: :plan_revision)

    assert ["[plan revised] The plan changed.", "[plan revised] In full:"] =
             Enum.map(Pipeline.list_run_events(run), & &1.line)
  end

  test "a working run that has not recorded its conversation yet still queues", %{task: task, role: role} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        started_at: DateTime.utc_now()
      })

    assert {:ok, :queued, %Run{pending_chat: "Anyone there?"}} =
             Pipeline.send_message(system_scope(), run, "Anyone there?")
  end

  test "a run holding no conversation cannot be messaged", %{task: task, role: role} do
    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        started_at: DateTime.utc_now()
      })

    assert {:error, :chat_unavailable} = Pipeline.send_message(system_scope(), run, "Anyone there?")
  end

  test "an empty message is not a message", %{idle: idle} do
    run = idle.()

    assert {:error, :empty_message} = Pipeline.send_message(system_scope(), run, "   ")
    assert {:error, :empty_message} = Pipeline.send_message(system_scope(), run, nil)
  end

  test "a run that is gone cannot be messaged", %{idle: idle} do
    run = idle.()
    Repo.delete!(run)

    assert {:error, :not_found} = Pipeline.send_message(system_scope(), run, "Hello?")
  end
end
