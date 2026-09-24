defmodule Rail.Pipeline.Actions.StopAndSendMessageTest do
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
              "id" => "lin_stop_and_send_1",
              "identifier" => "SAS-1",
              "title" => "Stop And Send Issue"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Stop And Send Issue"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    working = fn attrs ->
      {:ok, run} =
        Pipeline.create_run(
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

    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, :sent, %Run{}} = Pipeline.stop_and_send_message(run)
  end

  test "there is nothing to send now when nothing was queued", %{working: working} do
    run = working.(%{})

    assert {:error, :nothing_queued} = Pipeline.stop_and_send_message(run)
  end
end
