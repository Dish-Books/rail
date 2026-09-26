defmodule Rail.Users.Actions.LinkSlackTest do
  use Rail.DataCase, async: true

  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "ls_#{unique}", login: "ls_#{unique}", email: "ls_#{unique}@example.com"})

    team_id = "T#{unique}"
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
    {:ok, _workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-bot"})

    %{user: user, scope: Scope.for_user(user), team_id: team_id}
  end

  test "trades the code for the person's token and stores who they are", %{scope: scope, team_id: team_id} do
    Req.Test.expect(Slack, fn conn ->
      assert conn.request_path == "/api/oauth.v2.access"

      Req.Test.json(conn, %{
        "ok" => true,
        "team" => %{"id" => team_id},
        "authed_user" => %{"id" => "U_PRIYA", "access_token" => "xoxp-priya"}
      })
    end)

    Req.Test.expect(Slack, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer xoxb-bot"]
      assert %{"user" => "U_PRIYA"} = conn.query_params
      Req.Test.json(conn, %{"ok" => true, "user" => %{"id" => "U_PRIYA", "real_name" => "Priya Natarajan"}})
    end)

    assert {:ok,
            %User{
              slack_user_id: "U_PRIYA",
              slack_team_id: ^team_id,
              slack_name: "Priya Natarajan",
              slack_access_token: "xoxp-priya"
            }} = Users.link_slack(scope, "c0de")
  end

  test "links nothing when the code exchange fails", %{scope: scope, user: user} do
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "invalid_code"}))

    assert {:error, {:slack_error, "invalid_code"}} = Users.link_slack(scope, "bad")
    assert %User{slack_access_token: nil} = Repo.reload!(user)
  end

  test "refuses a workspace Rail has not been installed in", %{scope: scope} do
    Req.Test.expect(Slack, fn conn ->
      Req.Test.json(conn, %{
        "ok" => true,
        "team" => %{"id" => "T_ELSEWHERE"},
        "authed_user" => %{"id" => "U1", "access_token" => "xoxp-1"}
      })
    end)

    assert {:error, :slack_workspace_not_found} = Users.link_slack(scope, "c0de")
  end

  test "needs a signed-in user" do
    assert {:error, :not_authenticated} = Users.link_slack(Scope.for_system(), "c0de")
  end
end
