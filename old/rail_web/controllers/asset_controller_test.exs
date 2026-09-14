defmodule RailWeb.AssetControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{conn: conn} do
    id = System.unique_integer([:positive])

    assert {:ok, %User{} = user} =
             Users.register_oauth_user(%{
               github_id: "asset_ctrl_gh_#{id}",
               login: "asset_user_#{id}",
               name: "Asset User #{id}",
               email: "asset_#{id}@example.com"
             })

    user_token = Users.generate_user_session_token(user)

    authed_conn =
      conn
      |> Map.replace!(:secret_key_base, RailWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> put_session(:user_token, user_token)

    %{conn: conn, authed_conn: authed_conn, user: user}
  end

  describe "GET /assets/:kind/:id" do
    test "redirects unauthenticated user to github login", %{conn: conn} do
      conn = get(conn, ~p"/assets/demo/some_id")
      assert redirected_to(conn) == ~p"/auth/github"
    end

    test "returns 404 when asset does not exist on any artifact", %{authed_conn: conn} do
      conn = get(conn, ~p"/assets/demo/nonexistent_asset_id")
      assert response(conn, 404) =~ "Not found"
    end

    test "returns 502 when Linear workspace token is missing", %{authed_conn: conn} do
      {:ok, _demo} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_no_ws",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          segments: [
            %{
              criterion_index: 1,
              criterion: "Criterion 1",
              outcome: :recorded,
              frames: [
                %{
                  linear_asset_id: "ast_no_ws",
                  url: "https://uploads.linear.app/asset/no_ws.png",
                  caption: "Frame"
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      conn = get(conn, ~p"/assets/demo/ast_no_ws")
      assert response(conn, 502) =~ "Linear workspace token not configured"
    end

    test "proxies demo frame asset", %{authed_conn: conn} do
      {:ok, _ws} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Asset Controller Workspace 12802",
          external_id: "lin_ws_asset_controller_12802",
          token: "lin_api_token_asset_controller_12802",
          webhook_secret: "whsec_asset_controller_12802"
        })

      {:ok, _demo} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_demo_proxy",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          segments: [
            %{
              criterion_index: 1,
              criterion: "Criterion 1",
              outcome: :recorded,
              frames: [
                %{
                  linear_asset_id: "ast_frame_proxy",
                  url: "https://uploads.linear.app/asset/demo_frame.png",
                  caption: "Frame"
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      Req.Test.expect(Rail.Linear, fn req_conn ->
        assert req_conn.request_path == "/asset/demo_frame.png"

        req_conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "DEMO_FRAME_BINARY")
      end)

      conn = get(conn, ~p"/assets/demo/ast_frame_proxy")
      assert response(conn, 200) == "DEMO_FRAME_BINARY"
    end

    test "proxies QA artifact asset", %{authed_conn: conn} do
      {:ok, _ws} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Asset Controller Workspace 12803",
          external_id: "lin_ws_asset_controller_12803",
          token: "lin_api_token_asset_controller_12803",
          webhook_secret: "whsec_asset_controller_12803"
        })

      {:ok, _qa} =
        %QaReport{}
        |> QaReport.changeset(%{
          task_id: "tsk_qa_proxy",
          session: %{},
          rows: [
            %{
              id: "c1",
              check: "Check A",
              result: :pass,
              severity: :blocker,
              artifacts: [
                %{
                  name: "qa_evidence.png",
                  kind: :image,
                  url: "https://uploads.linear.app/asset/qa_evidence.png"
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      Req.Test.expect(Rail.Linear, fn req_conn ->
        assert req_conn.request_path == "/asset/qa_evidence.png"

        req_conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "QA_EVIDENCE_BINARY")
      end)

      conn = get(conn, ~p"/assets/qa/qa_evidence.png")
      assert response(conn, 200) == "QA_EVIDENCE_BINARY"
    end

    test "returns 502 when upstream Linear returns non-200", %{authed_conn: conn} do
      {:ok, _ws} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Asset Controller Workspace 12804",
          external_id: "lin_ws_asset_controller_12804",
          token: "lin_api_token_asset_controller_12804",
          webhook_secret: "whsec_asset_controller_12804"
        })

      {:ok, _demo} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_err_upstream",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          segments: [
            %{
              criterion_index: 1,
              criterion: "Criterion 1",
              outcome: :recorded,
              frames: [
                %{
                  linear_asset_id: "ast_upstream_err",
                  url: "https://uploads.linear.app/asset/err.png",
                  caption: "Frame"
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      Req.Test.expect(Rail.Linear, fn req_conn ->
        Plug.Conn.send_resp(req_conn, 500, "Upstream error")
      end)

      conn = get(conn, ~p"/assets/demo/ast_upstream_err")
      assert response(conn, 502) =~ "Failed to fetch asset from Linear: HTTP 500"
    end

    test "returns 502 on transport error", %{authed_conn: conn} do
      {:ok, _ws} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Asset Controller Workspace 12805",
          external_id: "lin_ws_asset_controller_12805",
          token: "lin_api_token_asset_controller_12805",
          webhook_secret: "whsec_asset_controller_12805"
        })

      {:ok, _demo} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_transport_err",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          segments: [
            %{
              criterion_index: 1,
              criterion: "Criterion 1",
              outcome: :recorded,
              frames: [
                %{
                  linear_asset_id: "ast_transport_err",
                  url: "https://uploads.linear.app/asset/transport.png",
                  caption: "Frame"
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      Req.Test.expect(Rail.Linear, fn req_conn ->
        Req.Test.transport_error(req_conn, :econnrefused)
      end)

      conn = get(conn, ~p"/assets/demo/ast_transport_err")
      assert response(conn, 502) =~ "Failed to fetch asset from Linear:"
    end

    test "handles system scope and unauthorized scope directly", %{conn: conn} do
      {:ok, _ws} =
        Projects.upsert_linear_workspace(system_scope(), %{
          name: "Asset Controller Workspace 12806",
          external_id: "lin_ws_asset_controller_12806",
          token: "lin_api_token_asset_controller_12806",
          webhook_secret: "whsec_asset_controller_12806"
        })

      {:ok, _demo} =
        %Demo{}
        |> Demo.changeset(%{
          task_id: "tsk_system_scope",
          version: 1,
          recorded_at: DateTime.utc_now(),
          outcome: "recorded",
          segments: [
            %{
              criterion_index: 1,
              criterion: "Criterion 1",
              outcome: :recorded,
              frames: [
                %{
                  linear_asset_id: "ast_sys",
                  url: "https://uploads.linear.app/asset/sys.png",
                  caption: "Frame"
                }
              ]
            }
          ]
        })
        |> Repo.insert()

      Req.Test.expect(Rail.Linear, fn req_conn ->
        Plug.Conn.send_resp(req_conn, 200, "SYS_BYTES")
      end)

      sys_conn =
        conn
        |> assign(:current_scope, Rail.Scope.for_system())
        |> RailWeb.AssetController.show(%{"kind" => "demo", "id" => "ast_sys"})

      assert sys_conn.status == 200
      assert sys_conn.resp_body == "SYS_BYTES"

      unauth_conn =
        conn
        |> assign(:current_scope, %Rail.Scope{user: nil, system: false})
        |> RailWeb.AssetController.show(%{"kind" => "demo", "id" => "ast_sys"})

      assert unauth_conn.status == 401
      assert unauth_conn.resp_body == "Unauthorized"
    end
  end
end
