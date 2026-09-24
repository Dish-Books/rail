defmodule RailWeb.LinearWebhookControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  test "returns 404 when workspace does not exist", %{conn: conn} do
    body = Jason.encode!(%{"type" => "Issue", "action" => "create", "organizationId" => "lin_org_unknown"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", "dummy_sig")
      |> post(~p"/webhooks/linear", body)

    assert json_response(conn, 404)["error"] == "Workspace not found"
  end

  test "returns 401 when signature is missing or invalid", %{conn: conn} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, %Project{linear_workspace: %LinearWorkspace{external_id: external_id}}} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Project 12900",
        github_repo: "org/webhook-12900",
        github_installation_id: 12_900,
        linear_team_key: "P12900",
        default_branch: "main",
        clone_path: "/tmp/repos/webhook-12900",
        linear_workspace: %{
          name: "Webhook Workspace 12900",
          external_id: "lin_ws_webhook_12900",
          token: "lin_api_token_webhook_12900",
          webhook_secret: "whsec_webhook_12900"
        }
      })

    body = Jason.encode!(%{"type" => "Issue", "action" => "create", "organizationId" => external_id})

    conn_no_sig =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/linear", body)

    assert json_response(conn_no_sig, 401)["error"] == "Invalid signature"

    conn_bad_sig =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", "invalid_signature")
      |> post(~p"/webhooks/linear", body)

    assert json_response(conn_bad_sig, 401)["error"] == "Invalid signature"
  end

  test "accepts a signed Issue event and mirrors the issue locally", %{conn: conn} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, %Project{id: project_id, linear_workspace: %LinearWorkspace{external_id: external_id, webhook_secret: secret}}} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Project 12903",
        github_repo: "org/webhook-12903",
        github_installation_id: 12_903,
        linear_team_key: "P12903",
        default_branch: "main",
        clone_path: "/tmp/repos/webhook-12903",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Webhook Workspace 12903",
          external_id: "lin_ws_webhook_12903",
          token: "lin_api_token_webhook_12903",
          webhook_secret: "whsec_webhook_12903"
        }
      })

    payload = %{
      "type" => "Issue",
      "action" => "create",
      "organizationId" => external_id,
      "data" => %{
        "id" => "lin_wh_iss_1",
        "identifier" => "ENG-777",
        "title" => "Webhook Issue",
        "description" => "Created via webhook",
        "teamId" => "lin_team_id",
        "state" => %{"id" => "st_started", "name" => "In Progress", "type" => "started"},
        "branchName" => "eng-777-webhook",
        "url" => "https://linear.app/issue/ENG-777",
        "createdAt" => "2026-09-08T10:00:00.000Z",
        "updatedAt" => "2026-09-08T11:00:00.000Z"
      }
    }

    raw_body = Jason.encode!(payload)
    signature = :hmac |> :crypto.mac(:sha256, secret, raw_body) |> Base.encode16(case: :lower)

    res_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", signature)
      |> post(~p"/webhooks/linear", raw_body)

    assert json_response(res_conn, 200)["received"] == true

    assert %Issue{
             project_id: ^project_id,
             identifier: "ENG-777",
             title: "Webhook Issue",
             state: :in_progress
           } = Repo.get_by(Issue, external_id: "lin_wh_iss_1")
  end
end
