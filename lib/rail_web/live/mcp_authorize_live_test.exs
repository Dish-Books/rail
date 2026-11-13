defmodule RailWeb.McpAuthorizeLiveTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthAuthorizationCode
  alias Rail.Repo
  alias Rail.Users

  setup %{project: project, github_project: github} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "mal_#{id}",
        login: "mal_#{id}",
        name: "Mal",
        email: "mal_#{id}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id, github.id]})

    {:ok, client, nil} =
      Mcp.register_dynamic_client(%{
        "client_name" => "Claude Code",
        "redirect_uris" => ["http://localhost/callback", "https://claude.ai/api/mcp/auth_callback"]
      })

    params = %{
      "response_type" => "code",
      "client_id" => client.client_id,
      "redirect_uri" => "http://localhost:43210/callback",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, "verifier"), padding: false),
      "code_challenge_method" => "S256",
      "state" => "st-1",
      "scope" => "mcp"
    }

    %{user: user, client: client, params: params}
  end

  test "names the client, the person's projects and where they will be sent, with the own-computer note", %{
    conn: conn,
    user: user,
    params: params,
    project: project,
    github_project: github
  } do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")

    assert has_element?(view, "#mcp-client-name", "Claude Code")
    assert has_element?(view, "#mcp-authorize", user.login)
    assert has_element?(view, "#mcp-project-#{project.id}", project.key)
    assert has_element?(view, "#mcp-project-#{github.id}", github.key)
    assert has_element?(view, "#mcp-redirect-host", "localhost")
    assert has_element?(view, "#mcp-loopback-note", "Only continue if you started this connection yourself.")
  end

  test "a web client gets no own-computer note", %{conn: conn, user: user, params: params} do
    params = %{params | "redirect_uri" => "https://claude.ai/api/mcp/auth_callback"}
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")

    assert has_element?(view, "#mcp-redirect-host", "claude.ai")
    refute has_element?(view, "#mcp-loopback-note")
  end

  test "Allow sends a code and the state back, once", %{conn: conn, user: %{id: user_id} = user, params: params} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")

    assert {:error, {:redirect, %{to: url}}} = view |> element("#mcp-allow") |> render_click()
    assert %URI{host: "localhost", port: 43_210, path: "/callback", query: query} = URI.parse(url)
    assert %{"code" => "rail.ac." <> _rest, "state" => "st-1"} = URI.decode_query(query)
    assert [%OauthAuthorizationCode{}] = Repo.all(from(c in OauthAuthorizationCode, where: c.user_id == ^user_id))
  end

  test "a second Allow while the first redirect is on its way issues no second code", %{
    conn: conn,
    user: %{id: user_id} = user,
    params: params
  } do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")
    :sys.replace_state(view.pid, fn state -> put_in(state.socket.assigns.authorized, true) end)

    render_click(view, "authorize", %{})
    assert [] = Repo.all(from(c in OauthAuthorizationCode, where: c.user_id == ^user_id))
  end

  test "Cancel sends access_denied and the state back, and connects nothing", %{
    conn: conn,
    user: %{id: user_id} = user,
    params: params
  } do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")

    assert {:error, {:redirect, %{to: url}}} = view |> element("#mcp-cancel") |> render_click()
    assert %{"error" => "access_denied", "state" => "st-1"} = URI.decode_query(URI.parse(url).query)
    assert [] = Repo.all(from(c in OauthAuthorizationCode, where: c.user_id == ^user_id))
  end

  test "Cancel without a state sends none", %{conn: conn, user: user, params: params} do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{Map.delete(params, "state")}")

    assert {:error, {:redirect, %{to: url}}} = view |> element("#mcp-cancel") |> render_click()
    assert %{"error" => "access_denied"} = query = URI.decode_query(URI.parse(url).query)
    refute Map.has_key?(query, "state")
  end

  test "a request Rail cannot trust renders an error and redirects nowhere", %{conn: conn, user: user, params: params} do
    conn = log_in_user(conn, user)

    for {change, error, description} <- [
          {%{"redirect_uri" => "https://evil.example/callback"}, "invalid_request", "The return address does not match"},
          {%{"scope" => "admin"}, "invalid_scope", "only ask for the mcp scope"},
          {%{"client_id" => "unknown"}, "invalid_client", "Rail does not know this client"},
          {%{"resource" => "https://elsewhere.example/mcp"}, "invalid_target", "a server other than this Rail"},
          {%{"response_type" => "token"}, "unsupported_response_type", "response_type=code"},
          {%{"code_challenge" => nil}, "invalid_pkce", "PKCE"}
        ] do
      {:ok, view, _html} = live(conn, ~p"/oauth/mcp/authorize?#{Map.merge(params, change)}")

      assert has_element?(view, "#mcp-authorize-error", "Authorization request invalid")
      assert has_element?(view, "#mcp-authorize-error", "error = #{error}")
      assert has_element?(view, "#mcp-authorize-error", description)
      refute has_element?(view, "#mcp-allow")
    end
  end

  test "a person who can open no project gets access_denied", %{conn: conn, user: user, params: params} do
    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: []})
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")

    assert has_element?(view, "#mcp-authorize-error", "error = access_denied")
  end

  test "someone who disconnected GitHub is told to connect it, and nothing is issued", %{
    conn: conn,
    user: %{id: user_id} = user,
    params: params
  } do
    {:ok, user} = Users.unlink_github(Rail.Scope.for_user(user))
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")

    assert has_element?(view, "#mcp-authorize-error", "error = github_required")
    assert has_element?(view, "#mcp-authorize-error", "Connect GitHub under Settings, Connected accounts")
    refute has_element?(view, "#mcp-allow")
    assert [] = Repo.all(from(c in OauthAuthorizationCode, where: c.user_id == ^user_id))
  end

  test "a client gone before Allow renders the error instead", %{
    conn: conn,
    user: user,
    client: client,
    params: params
  } do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")
    Repo.delete!(client)

    view |> element("#mcp-allow") |> render_click()
    assert has_element?(view, "#mcp-authorize-error", "error = invalid_client")
  end

  test "a signed-out person is sent to sign in and comes back to the consent page after", %{
    conn: conn,
    user: user,
    params: params
  } do
    path = ~p"/oauth/mcp/authorize?#{params}"
    conn = get(conn, path)

    assert redirected_to(conn) == ~p"/sign-in"
    assert ^path = return_to = get_session(conn, :user_return_to)

    signed_in = build_conn() |> init_test_session(%{user_return_to: return_to}) |> RailWeb.UserAuth.log_in_user(user)
    assert redirected_to(signed_in) == path
  end
end
