defmodule RailWeb.OAuthAuthorizationControllerTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Mcp
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    id = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "oac_#{id}",
        login: "oac_#{id}",
        name: "Oac",
        email: "oac_#{id}@example.com"
      })

    {:ok, user} = Users.update_user(system_scope(), user, %{project_ids: [project.id]})
    %{user: user}
  end

  test "a public client registers, is allowed, exchanges its code and lists Rail's ticket tools at /mcp", %{
    conn: conn,
    user: user
  } do
    assert %{"client_id" => client_id, "token_endpoint_auth_method" => "none", "scope" => "mcp"} =
             registered =
             conn
             |> post(~p"/oauth/register", %{
               "client_name" => "Claude Code",
               "redirect_uris" => ["http://localhost/callback"]
             })
             |> json_response(201)

    refute Map.has_key?(registered, "client_secret")

    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    params = %{
      "response_type" => "code",
      "client_id" => client_id,
      "redirect_uri" => "http://localhost:6060/callback",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
      "code_challenge_method" => "S256",
      "state" => "abc"
    }

    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/oauth/mcp/authorize?#{params}")
    {:error, {:redirect, %{to: url}}} = view |> element("#mcp-allow") |> render_click()
    %{"code" => code, "state" => "abc"} = URI.decode_query(URI.parse(url).query)

    token_conn =
      post(build_conn(), ~p"/oauth/token", %{
        "grant_type" => "authorization_code",
        "client_id" => client_id,
        "code" => code,
        "redirect_uri" => "http://localhost:6060/callback",
        "code_verifier" => verifier
      })

    assert ["no-store"] = get_resp_header(token_conn, "cache-control")

    assert %{"access_token" => access_token, "refresh_token" => _refresh, "token_type" => "Bearer", "scope" => "mcp"} =
             json_response(token_conn, 200)

    mcp = fn conn, message ->
      conn
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> post(~p"/mcp", Jason.encode!(message))
    end

    # Anubis answers a request on the event stream: the message is the `data:` line.
    read = fn conn ->
      [data] = for "data: " <> data <- conn |> response(200) |> String.split("\n"), do: data
      Jason.decode!(data)
    end

    initialized =
      mcp.(build_conn(), %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "test", "version" => "1"}
        }
      })

    assert %{"result" => %{"serverInfo" => %{"name" => "rail"}}} = read.(initialized)
    [session_id] = get_resp_header(initialized, "mcp-session-id")
    session = put_req_header(build_conn(), "mcp-session-id", session_id)

    mcp.(session, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

    assert %{"result" => %{"tools" => tools}} =
             session |> mcp.(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}) |> read.()

    assert [
             "create_comment",
             "create_issue",
             "get_issue",
             "list_issues",
             "list_projects",
             "search_issues",
             "update_issue"
           ] =
             tools |> Enum.map(& &1["name"]) |> Enum.sort()
  end

  test "a confidential client sees its secret once and authenticates with it, by Basic or in the body", %{
    conn: conn,
    user: user
  } do
    for method <- ["client_secret_basic", "client_secret_post"] do
      assert %{"client_id" => client_id, "client_secret" => secret, "client_secret_expires_at" => 0} =
               conn
               |> post(~p"/oauth/register", %{
                 "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
                 "token_endpoint_auth_method" => method
               })
               |> json_response(201)

      verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      {:ok, %{redirect_url: url}} =
        Mcp.authorize(Scope.for_user(user), %{
          "client_id" => client_id,
          "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
          "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
          "code_challenge_method" => "S256"
        })

      grant = %{
        "grant_type" => "authorization_code",
        "code" => URI.decode_query(URI.parse(url).query)["code"],
        "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
        "code_verifier" => verifier
      }

      authenticated =
        case method do
          "client_secret_basic" ->
            put_req_header(build_conn(), "authorization", Plug.BasicAuth.encode_basic_auth(client_id, secret))

          "client_secret_post" ->
            build_conn()
        end

      grant =
        if method == "client_secret_post",
          do: Map.merge(grant, %{"client_id" => client_id, "client_secret" => secret}),
          else: grant

      assert %{"refresh_token" => refresh_token} = authenticated |> post(~p"/oauth/token", grant) |> json_response(200)

      assert %{"access_token" => "rail.at." <> _rest} =
               authenticated
               |> post(
                 ~p"/oauth/token",
                 Map.take(Map.merge(grant, %{"grant_type" => "refresh_token", "refresh_token" => refresh_token}), [
                   "grant_type",
                   "refresh_token",
                   "client_id",
                   "client_secret"
                 ])
               )
               |> json_response(200)
    end
  end

  test "registration refuses a redirect URI or metadata Rail does not support", %{conn: conn} do
    assert %{"error" => "invalid_redirect_uri"} =
             conn |> post(~p"/oauth/register", %{"redirect_uris" => ["http://evil.example/cb"]}) |> json_response(400)

    assert %{"error" => "invalid_client_metadata"} =
             conn
             |> post(~p"/oauth/register", %{"redirect_uris" => ["https://a.b/c"], "grant_types" => ["password"]})
             |> json_response(400)
  end

  test "the token endpoint answers each failure in OAuth's shape", %{conn: conn} do
    {:ok, %{client_id: client_id}, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["https://a.b/c"]})

    assert %{"error" => "invalid_client"} =
             conn |> post(~p"/oauth/token", %{"grant_type" => "authorization_code"}) |> json_response(401)

    assert %{"error" => "invalid_client"} =
             conn
             |> post(~p"/oauth/token", %{"client_id" => "nobody", "grant_type" => "refresh_token"})
             |> json_response(401)

    for {params, status, error} <- [
          {%{}, 400, "invalid_request"},
          {%{"grant_type" => "password"}, 400, "unsupported_grant_type"},
          {%{"grant_type" => "authorization_code", "code" => "rail.ac.x.y"}, 400, "invalid_grant"},
          {%{"grant_type" => "authorization_code", "resource" => "https://elsewhere.example/mcp"}, 400, "invalid_target"}
        ] do
      assert %{"error" => ^error, "error_description" => _description} =
               conn |> post(~p"/oauth/token", Map.put(params, "client_id", client_id)) |> json_response(status)
    end
  end
end
