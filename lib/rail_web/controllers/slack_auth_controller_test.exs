defmodule RailWeb.SlackAuthControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Slack
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "sac_#{unique}", login: "sac_#{unique}", email: "sac_#{unique}@example.com"})

    %{conn: log_in_user(conn, user), user: user, team_id: "T#{unique}"}
  end

  test "sends the person to Slack with a state kept in the session", %{conn: conn} do
    conn = get(conn, ~p"/auth/slack")

    state = get_session(conn, :slack_oauth_state)
    assert "https://slack.com/oauth/v2/authorize?" <> query = redirected_to(conn, 302)
    assert %{"user_scope" => "chat:write", "state" => ^state} = URI.decode_query(query)
  end

  test "a good state links the account", %{conn: conn, user: user, team_id: team_id} do
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => team_id}))
    {:ok, _workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-bot"})

    Req.Test.expect(Slack, fn conn ->
      Req.Test.json(conn, %{
        "ok" => true,
        "team" => %{"id" => team_id},
        "authed_user" => %{"id" => "U1", "access_token" => "xoxp-1"}
      })
    end)

    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => true, "user" => %{"real_name" => "Sam"}}))

    conn =
      conn
      |> put_session(:slack_oauth_state, "st")
      |> get(~p"/auth/slack/callback", %{"code" => "c0de", "state" => "st"})

    assert redirected_to(conn) == ~p"/settings/connected-accounts"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected Slack account"
    assert %User{slack_access_token: "xoxp-1", slack_name: "Sam"} = Repo.reload!(user)
  end

  test "a link Slack refuses is reported", %{conn: conn} do
    Req.Test.expect(Slack, &Req.Test.json(&1, %{"ok" => false, "error" => "invalid_code"}))

    conn =
      conn
      |> put_session(:slack_oauth_state, "st")
      |> get(~p"/auth/slack/callback", %{"code" => "c0de", "state" => "st"})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to connect Slack account"
  end

  test "a bad state is refused without asking Slack", %{conn: conn, user: user} do
    conn =
      conn
      |> put_session(:slack_oauth_state, "real")
      |> get(~p"/auth/slack/callback", %{"code" => "c0de", "state" => "forged"})

    assert redirected_to(conn) == ~p"/settings/connected-accounts"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Slack authentication failed"
    assert %User{slack_access_token: nil} = Repo.reload!(user)
  end

  test "a denied request redirects with an error", %{conn: conn} do
    conn = get(conn, ~p"/auth/slack/callback", %{"error" => "access_denied"})

    assert redirected_to(conn) == ~p"/settings/connected-accounts"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Slack authentication was denied or cancelled"
  end

  test "a callback with neither a code nor an error is refused", %{conn: conn} do
    conn = get(conn, ~p"/auth/slack/callback", %{})

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Slack authentication failed"
  end
end
