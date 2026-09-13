defmodule Rail.Linear.ClientTest do
  use Rail.DataCase, async: true

  import ExUnit.CaptureLog

  alias Rail.Linear
  alias Rail.Linear.Client
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Scope
  alias Rail.Users

  setup do
    %{project: %Project{linear_team_key: "TEAM", linear_workspace: %LinearWorkspace{token: "ws_token"}}}
  end

  describe "authorize_url/1" do
    test "builds default authorize URL with configured parameters" do
      url = Client.authorize_url()

      assert String.starts_with?(url, "https://linear.app/oauth/authorize?")
      config = Application.fetch_env!(:rail, :linear_oauth)
      assert String.contains?(url, "client_id=#{config[:client_id]}")

      assert String.contains?(
               url,
               "redirect_uri=#{URI.encode_www_form(RailWeb.Endpoint.url() <> "/auth/linear/callback")}"
             )

      assert String.contains?(url, "response_type=code")
      assert String.contains?(url, "actor=user")
      assert String.contains?(url, "scope=read%2Cwrite%2Cissues%3Acreate%2Ccomments%3Acreate")
      refute String.contains?(url, "state=")
    end

    test "includes state parameter and allows overriding options" do
      url =
        Client.authorize_url(
          client_id: "custom_client",
          state: "csrf_state_123",
          scope: "read"
        )

      assert String.contains?(url, "client_id=custom_client")
      assert String.contains?(url, "state=csrf_state_123")
      assert String.contains?(url, "scope=read")
    end

    test "Rail.Linear delegates authorize_url" do
      assert Linear.authorize_url() == Client.authorize_url()
    end
  end

  describe "exchange_code/2" do
    test "returns Linear's token response" do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["grant_type"] == "authorization_code"

        Req.Test.json(conn, %{
          "access_token" => "lin_access_test_token",
          "expires_in" => 7200,
          "refresh_token" => "lin_refresh_test_token"
        })
      end)

      assert {:ok,
              %{
                "access_token" => "lin_access_test_token",
                "refresh_token" => "lin_refresh_test_token",
                "expires_in" => 7200
              }} = Client.exchange_code("valid_auth_code")
    end

    test "returns error on token endpoint failure" do
      Req.Test.expect(Linear, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, {:linear_oauth_error, 400, %{"error" => "invalid_grant"}}} =
               Client.exchange_code("invalid_code")
    end

    test "returns error on network transport failure" do
      Req.Test.expect(Linear, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = Client.exchange_code("some_code")
    end

    test "Rail.Linear delegates exchange_code" do
      Req.Test.expect(Linear, fn conn -> Req.Test.json(conn, %{"access_token" => "delegated_access_token"}) end)

      assert {:ok, %{"access_token" => "delegated_access_token"}} = Linear.exchange_code("code_for_delegate")
    end
  end

  describe "refresh_token/2" do
    test "returns Linear's token response" do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body)["grant_type"] == "refresh_token"

        Req.Test.json(conn, %{
          "access_token" => "lin_new_access_token",
          "expires_in" => 3600,
          "refresh_token" => "lin_new_refresh_token"
        })
      end)

      assert {:ok, %{"access_token" => "lin_new_access_token", "refresh_token" => "lin_new_refresh_token"}} =
               Client.refresh_token("existing_refresh_token")
    end

    test "returns error on refresh failure" do
      Req.Test.expect(Linear, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, {:linear_token_refresh_error, 400, %{"error" => "invalid_grant"}}} =
               Client.refresh_token("expired_refresh_token")
    end

    test "returns error on transport error during refresh" do
      Req.Test.expect(Linear, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Req.TransportError{reason: :timeout}} = Client.refresh_token("timeout_token")
    end

    test "Rail.Linear delegates refresh_token" do
      Req.Test.expect(Linear, fn conn -> Req.Test.json(conn, %{"access_token" => "delegated_refresh_at"}) end)

      assert {:ok, %{"access_token" => "delegated_refresh_at"}} = Linear.refresh_token("rt_for_delegate")
    end
  end

  describe "viewer/2" do
    test "returns the viewer data" do
      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer valid_access_token"]
        Req.Test.json(conn, %{"data" => %{"viewer" => %{"id" => "viewer_usr_456", "name" => "Alice Linear"}}})
      end)

      assert {:ok, %{"viewer" => %{"id" => "viewer_usr_456", "name" => "Alice Linear"}}} =
               Client.viewer("valid_access_token")
    end

    test "returns API errors" do
      Req.Test.expect(Linear, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"errors" => [%{"message" => "Not authenticated"}]})
      end)

      assert {:error, {:linear_api_error, 401, %{"errors" => _errors}}} = Client.viewer("bad_token")
    end

    test "returns GraphQL errors sent with a 200" do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.json(conn, %{"errors" => [%{"message" => "Field does not exist"}]})
      end)

      assert {:error, {:linear_graphql_error, [%{"message" => "Field does not exist"}]}} = Client.viewer("token")
    end

    test "returns transport errors" do
      Req.Test.expect(Linear, fn conn -> Req.Test.transport_error(conn, :nxdomain) end)

      assert {:error, %Req.TransportError{reason: :nxdomain}} = Client.viewer("token_nxdomain")
    end

    test "Rail.Linear delegates viewer" do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"viewer" => %{"id" => "delegate_viewer_id"}}})
      end)

      assert {:ok, %{"viewer" => %{"id" => "delegate_viewer_id"}}} = Linear.viewer("token_for_delegate")
    end
  end

  describe "tokens" do
    test "a call goes out as the workspace by default", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ws_token"]
        Req.Test.json(conn, %{"data" => %{"commentCreate" => %{"success" => true}}})
      end)

      assert {:ok, _data} = Client.create_comment(project, %{"issueId" => "lin_iss_1", "body" => "Hi"})
    end

    test "a call made as a linked user goes out with their token", %{project: project} do
      {:ok, user} =
        Users.register_oauth_user(%{github_id: "gh_client_linked", login: "client_linked", email: "linked@example.com"})

      {:ok, user} =
        Users.update_user(Scope.for_system(), user, %{
          linear_access_token: "lin_user_tok_1",
          linear_refresh_token: "lin_user_refresh_1",
          linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
        })

      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_user_tok_1"]
        Req.Test.json(conn, %{"data" => %{"commentCreate" => %{"success" => true}}})
      end)

      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_user_tok_1"]
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      input = %{"issueId" => "lin_iss_1", "body" => "Hi"}
      assert {:ok, _data} = Client.create_comment(project, input, as: Scope.for_user(user))
      assert {:ok, _data} = Client.update_issue(project, "lin_iss_1", %{"title" => "T"}, as: Scope.for_user(user))
    end

    test "a user who never linked Linear falls back to the workspace and says so", %{project: project} do
      {:ok, user} =
        Users.register_oauth_user(%{github_id: "gh_client_unlinked", login: "client_unlinked", email: "u@example.com"})

      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ws_token"]
        Req.Test.json(conn, %{"data" => %{"commentCreate" => %{"success" => true}}})
      end)

      log =
        capture_log(fn ->
          assert {:ok, _data} =
                   Client.create_comment(project, %{"issueId" => "lin_iss_1", "body" => "Hi"}, as: Scope.for_user(user))
        end)

      assert log =~ "[rail] pushed to Linear as the workspace"
    end

    test "a system scope goes out as the workspace without a warning", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ws_token"]
        Req.Test.json(conn, %{"data" => %{"commentCreate" => %{"success" => true}}})
      end)

      log =
        capture_log(fn ->
          assert {:ok, _data} =
                   Client.create_comment(project, %{"issueId" => "lin_iss_1", "body" => "Hi"}, as: Scope.for_system())
        end)

      refute log =~ "pushed to Linear as the workspace"
    end

    test "the workspace token is looked up when the project did not bring it" do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
      end)

      {:ok, project} =
        Rail.Projects.create_project(system_scope(), %{
          name: "Client Lookup Project",
          github_repo: "org/client-lookup",
          github_installation_id: 5311,
          linear_workspace: %{
            name: "Client Lookup Workspace",
            external_id: "lin_ws_client_lookup",
            token: "looked_up_token",
            webhook_secret: "whsec_client_lookup"
          },
          linear_team_key: "CLK",
          default_branch: "main",
          clone_path: "/tmp/repos/client-lookup"
        })

      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer looked_up_token"]
        Req.Test.json(conn, %{"data" => %{"issues" => %{"nodes" => []}}})
      end)

      assert {:ok, %{"issues" => %{"nodes" => []}}} =
               Client.issues(%Project{id: project.id, linear_team_key: "CLK"})
    end

    test "no workspace token means no request" do
      assert {:error, :no_workspace_token} = Client.issues(%Project{linear_team_key: "TEAM"})
      assert {:error, :no_workspace_token} = Client.file_upload(nil, "f.png", "image/png", "x")
    end
  end

  describe "issues/2" do
    test "asks for a page of the issues on the team with the project's key", %{project: project} do
      page = %{
        "issues" => %{
          "nodes" => [%{"id" => "lin_iss_1", "identifier" => "TEAM-1"}],
          "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor_1"}
        }
      }

      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"teamKey" => "TEAM", "first" => 100, "after" => nil} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => page})
      end)

      assert {:ok, ^page} = Client.issues(project)
    end

    test "continues from a cursor", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"after" => "cursor_1"} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"issues" => %{"nodes" => []}}})
      end)

      assert {:ok, %{"issues" => %{"nodes" => []}}} = Client.issues(project, after: "cursor_1")
    end
  end

  describe "team/2" do
    test "looks the team up by the project's key", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"teamKey" => "TEAM"} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_uuid"}]}}})
      end)

      assert {:ok, %{"teams" => %{"nodes" => [%{"id" => "lin_team_uuid"}]}}} = Client.team(project)
    end
  end

  describe "create_issue/3" do
    test "sends the input", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert %{"input" => %{"teamId" => "lin_team_uuid", "title" => "New Bug", "priority" => 1}} =
                 Jason.decode!(body)["variables"]

        Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => false}}})
      end)

      assert {:ok, %{"issueCreate" => %{"success" => false}}} =
               Client.create_issue(project, %{"teamId" => "lin_team_uuid", "title" => "New Bug", "priority" => 1})
    end
  end

  describe "update_issue/4" do
    test "sends the input for the issue", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"id" => "lin_iss_1", "input" => %{"title" => "Updated"}} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"issueUpdate" => %{"success" => true}}})
      end)

      assert {:ok, %{"issueUpdate" => %{"success" => true}}} =
               Client.update_issue(project, "lin_iss_1", %{"title" => "Updated"})
    end
  end

  describe "create_comment/3" do
    test "sends the input", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"input" => %{"issueId" => "lin_iss_1", "body" => "Hello"}} = Jason.decode!(body)["variables"]
        Req.Test.json(conn, %{"data" => %{"commentCreate" => %{"success" => true, "comment" => %{"id" => "c_1"}}}})
      end)

      assert {:ok, %{"commentCreate" => %{"comment" => %{"id" => "c_1"}}}} =
               Client.create_comment(project, %{"issueId" => "lin_iss_1", "body" => "Hello"})
    end
  end

  describe "file_upload/5" do
    test "asks Linear where to put the file, then puts it there", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert %{"filename" => "diagram.png", "size" => 4} = Jason.decode!(body)["variables"]

        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{
              "success" => true,
              "uploadFile" => %{
                "uploadUrl" => "https://api.linear.app/upload/asset_999",
                "assetUrl" => "https://uploads.linear.app/asset_999/diagram.png",
                "headers" => [%{"key" => "x-goog-meta", "value" => "1"}]
              }
            }
          }
        })
      end)

      Req.Test.expect(Linear, fn conn ->
        assert conn.method == "PUT"
        assert Plug.Conn.get_req_header(conn, "x-goog-meta") == ["1"]
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:ok,
              %{"fileUpload" => %{"uploadFile" => %{"assetUrl" => "https://uploads.linear.app/asset_999/diagram.png"}}}} =
               Client.file_upload(project, "diagram.png", "image/png", "DATA")
    end

    test "puts nothing when Linear gives nowhere to put it" do
      Req.Test.expect(Linear, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer direct_ws_token"]
        Req.Test.json(conn, %{"data" => %{"fileUpload" => %{"success" => false}}})
      end)

      assert {:ok, %{"fileUpload" => %{"success" => false}}} =
               Client.file_upload(%LinearWorkspace{token: "direct_ws_token"}, "f.png", "image/png", "DATA")
    end

    test "returns an error when the PUT fails", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{"success" => true, "uploadFile" => %{"uploadUrl" => "https://api.linear.app/upload/a"}}
          }
        })
      end)

      Req.Test.expect(Linear, fn conn -> Plug.Conn.send_resp(conn, 500, "nope") end)

      assert {:error, {:linear_upload_error, 500, _body}} = Client.file_upload(project, "f.png", "image/png", "DATA")
    end

    test "returns a transport error from the PUT", %{project: project} do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "fileUpload" => %{"success" => true, "uploadFile" => %{"uploadUrl" => "https://api.linear.app/upload/a"}}
          }
        })
      end)

      Req.Test.expect(Linear, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.file_upload(project, "f.png", "image/png", "DATA")
    end
  end
end
