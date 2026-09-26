defmodule Rail.Triage.SocketManagerTest do
  # Sockets run under the application's registry and reach Slack from processes
  # no test owns, so the stubs are shared and nothing may run beside it.
  use Rail.DataCase, async: false

  import Rail.FakeSlack

  alias Rail.Projects
  alias Rail.Triage.SocketManager
  alias Rail.Triage.SocketRegistry

  setup do
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.Test.set_req_test_to_private() end)

    %{url: url} = fake_slack(self())

    Req.Test.stub(Rail.Slack, fn conn ->
      case conn.request_path do
        "/api/auth.test" -> Req.Test.json(conn, %{"ok" => true, "team_id" => "T#{System.unique_integer([:positive])}"})
        "/api/apps.connections.open" -> Req.Test.json(conn, %{"ok" => true, "url" => url})
      end
    end)

    {:ok, socketed} =
      Projects.create_slack_workspace(system_scope(), %{"name" => "A", "token" => "xoxb-a", "app_token" => "xapp-a"})

    {:ok, tokenless} = Projects.create_slack_workspace(system_scope(), %{"name" => "B", "token" => "xoxb-b"})
    supervisor = start_supervised!(DynamicSupervisor)

    %{socketed: socketed, tokenless: tokenless, supervisor: supervisor}
  end

  test "opens one socket per workspace with an app token, and restarts it when the workspace changes", %{
    socketed: socketed,
    tokenless: tokenless,
    supervisor: supervisor
  } do
    start_supervised!({SocketManager, enabled: true, supervisor: supervisor, backoff: 10})

    assert_receive {:fake_slack_connected, _first}, 5_000
    assert [{first_pid, _value}] = Registry.lookup(SocketRegistry, socketed.id)
    assert [] = Registry.lookup(SocketRegistry, tokenless.id)

    {:ok, _updated} = Projects.update_slack_workspace(system_scope(), socketed, %{"name" => "A2"})

    assert_receive {:fake_slack_connected, _second}, 5_000
    assert [{second_pid, _value}] = Registry.lookup(SocketRegistry, socketed.id)
    refute second_pid == first_pid

    {:ok, _updated} = Projects.update_slack_workspace(system_scope(), tokenless, %{"name" => "B2"})
    refute_receive {:fake_slack_connected, _third}, 100
  end

  test "starts nothing when sockets are switched off" do
    assert :ignore = SocketManager.start_link([])
  end
end
