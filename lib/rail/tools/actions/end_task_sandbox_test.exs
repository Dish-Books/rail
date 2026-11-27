defmodule Rail.Tools.Actions.EndTaskSandboxTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Sandbox

  setup %{project: project} do
    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "Ending"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    %{task: task}
  end

  test "takes the container and the disk away, and keeps the row as ended", %{task: task} do
    test_pid = self()

    Req.Test.stub(Docker, fn conn ->
      send(test_pid, {conn.method, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    live =
      Repo.insert!(%Sandbox{
        task_id: task.id,
        engine: :docker,
        image: "i",
        volume: "rail-v1",
        status: :running,
        container_id: "c1"
      })

    assert :ok = Tools.end_task_sandbox(task)
    assert_received {"DELETE", "/containers/c1", "force=true"}
    assert_received {"DELETE", "/volumes/rail-v1", ""}
    assert %Sandbox{status: :ended, container_id: nil, ended_at: %DateTime{}} = Repo.reload!(live)

    stopped = Repo.insert!(%Sandbox{task_id: task.id, engine: :docker, image: "i", volume: "rail-v2", status: :stopped})
    assert :ok = Tools.end_task_sandbox(task)
    refute_received {"DELETE", "/containers/" <> _id, _query}
    assert_received {"DELETE", "/volumes/rail-v2", ""}
    assert %Sandbox{status: :ended} = Repo.reload!(stopped)

    assert :ok = Tools.end_task_sandbox(task)
  end
end
