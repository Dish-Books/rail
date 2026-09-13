defmodule RailWeb.LinearWebhookControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias RailTest.Mocks.Linear, as: LinearMock

  test "returns 404 when workspace does not exist", %{conn: conn} do
    body = Jason.encode!(%{"type" => "Issue", "action" => "create"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", "dummy_sig")
      |> post(~p"/webhooks/linear/nonexistent_workspace_id", body)

    assert json_response(conn, 404)["error"] == "Workspace not found"
  end

  test "returns 401 when signature is missing or invalid or workspace has no secret", %{conn: conn} do
    {:ok, %Project{linear_workspace: %LinearWorkspace{id: ws_id}}} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Project 12900",
        github_repo: "org/webhook-12900",
        github_installation_id: 12_900,
        linear_team_id: "team_wh_401",
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

    body = Jason.encode!(%{"type" => "Issue", "action" => "create"})

    conn_no_sig =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/linear/#{ws_id}", body)

    assert json_response(conn_no_sig, 401)["error"] == "Invalid signature"

    conn_bad_sig =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", "invalid_signature")
      |> post(~p"/webhooks/linear/#{ws_id}", body)

    assert json_response(conn_bad_sig, 401)["error"] == "Invalid signature"
  end

  test "handles Issue create event and mirrors issue locally", %{conn: conn} do
    {:ok, %Project{id: project_id, linear_workspace: %LinearWorkspace{webhook_secret: secret} = workspace}} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Project 12903",
        github_repo: "org/webhook-12903",
        github_installation_id: 12_903,
        linear_team_id: "team_wh_1",
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
          name: "Webhook Workspace 12901",
          external_id: "lin_ws_webhook_12901",
          token: "lin_api_token_webhook_12901",
          webhook_secret: "whsec_webhook_12901"
        }
      })

    payload = %{
      "type" => "Issue",
      "action" => "create",
      "data" => %{
        "id" => "lin_wh_iss_1",
        "identifier" => "ENG-777",
        "title" => "Webhook Issue",
        "description" => "Created via webhook",
        "teamId" => "team_wh_1",
        "state" => %{
          "id" => "st_started",
          "name" => "In Progress",
          "type" => "started"
        },
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
      |> post(~p"/webhooks/linear/#{workspace.external_id}", raw_body)

    assert json_response(res_conn, 200)["received"] == true

    assert %Issue{
             id: "iss_" <> _id,
             project_id: ^project_id,
             external_id: "lin_wh_iss_1",
             identifier: "ENG-777",
             title: "Webhook Issue",
             state: :in_progress,
             state_name: "In Progress"
           } = Repo.get_by(Issue, external_id: "lin_wh_iss_1")
  end

  test "maps various state types", %{conn: conn} do
    {:ok, %Project{id: project_id, linear_workspace: %LinearWorkspace{id: ws_id, webhook_secret: secret}}} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Project 12905",
        github_repo: "org/webhook-12905",
        github_installation_id: 12_905,
        linear_team_id: "team_wh_default",
        linear_team_key: "P12905",
        default_branch: "main",
        clone_path: "/tmp/repos/webhook-12905",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Webhook Workspace 12902",
          external_id: "lin_ws_webhook_12902",
          token: "lin_api_token_webhook_12902",
          webhook_secret: "whsec_webhook_12902"
        }
      })

    states_to_test = [
      {"lin_wh_tri", "triage", :triage},
      {"lin_wh_back", "backlog", :backlog},
      {"lin_wh_unstarted", "unstarted", :backlog},
      {"lin_wh_canc", "canceled", :canceled},
      {"lin_wh_other", "unknown", :backlog}
    ]

    for {iss_id, type_str, expected_state} <- states_to_test do
      payload = %{
        "type" => "Issue",
        "action" => "create",
        "data" => %{
          "id" => iss_id,
          "identifier" => "ENG-" <> iss_id,
          "title" => "Title " <> iss_id,
          "description" => "Desc",
          "teamId" => nil,
          "state" => %{"name" => type_str, "type" => type_str},
          "updatedAt" => "invalid-iso"
        }
      }

      raw_body = Jason.encode!(payload)
      sig = :hmac |> :crypto.mac(:sha256, secret, raw_body) |> Base.encode16(case: :lower)

      res =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("linear-signature", sig)
        |> post(~p"/webhooks/linear/#{ws_id}", raw_body)

      assert json_response(res, 200)["received"] == true

      assert %Issue{project_id: ^project_id, state: ^expected_state} =
               Repo.get_by(Issue, external_id: iss_id)
    end
  end

  test "returns ok and skips upsert when workspace has no project", %{conn: conn} do
    {:ok, %LinearWorkspace{id: ws_id, webhook_secret: secret}} =
      Repo.insert(
        LinearWorkspace.changeset(%LinearWorkspace{}, %{
          name: "Webhook Workspace 12906",
          external_id: "lin_ws_webhook_12906",
          token: "lin_api_token_webhook_12906",
          webhook_secret: "whsec_webhook_12906"
        })
      )

    payload = %{
      "type" => "Issue",
      "action" => "create",
      "data" => %{
        "id" => "lin_wh_orphan",
        "title" => "Orphan",
        "teamId" => "team_none"
      }
    }

    raw = Jason.encode!(payload)
    sig = :hmac |> :crypto.mac(:sha256, secret, raw) |> Base.encode16(case: :lower)

    res =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", sig)
      |> post(~p"/webhooks/linear/#{ws_id}", raw)

    assert json_response(res, 200)["received"] == true
    assert Repo.get_by(Issue, external_id: "lin_wh_orphan") == nil
  end

  test "handles Issue update and remove events", %{conn: conn} do
    {:ok, %Project{linear_workspace: %LinearWorkspace{id: ws_id, webhook_secret: secret}} = project} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Project 12908",
        github_repo: "org/webhook-12908",
        github_installation_id: 12_908,
        linear_team_id: "team_wh_2",
        linear_team_key: "P12908",
        default_branch: "main",
        clone_path: "/tmp/repos/webhook-12908",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        },
        linear_workspace: %{
          name: "Webhook Workspace 12904",
          external_id: "lin_ws_webhook_12904",
          token: "lin_api_token_webhook_12904",
          webhook_secret: "whsec_webhook_12904"
        }
      })

    LinearMock.mock_create_issue_success(%{"id" => "lin_wh_iss_2", "identifier" => "ENG-888", "title" => "Initial Title"})

    {:ok, existing_issue} = Issues.create_issue(project, %{description: "Initial Title"})

    update_payload = %{
      "type" => "Issue",
      "action" => "update",
      "data" => %{
        "id" => "lin_wh_iss_2",
        "identifier" => "ENG-888",
        "title" => "Updated Webhook Title",
        "description" => "Updated description",
        "teamId" => "team_wh_2",
        "state" => %{
          "id" => "st_done",
          "name" => "Done",
          "type" => "completed"
        },
        "updatedAt" => "2026-09-08T12:00:00.000Z"
      }
    }

    raw_update = Jason.encode!(update_payload)
    sig_update = :hmac |> :crypto.mac(:sha256, secret, raw_update) |> Base.encode16(case: :lower)

    res_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", sig_update)
      |> post(~p"/webhooks/linear/#{ws_id}", raw_update)

    assert json_response(res_conn, 200)["received"] == true

    updated = Repo.reload!(existing_issue)
    assert updated.title == "Updated Webhook Title"
    assert updated.state == :done

    # Test remove action
    remove_payload = %{
      "type" => "Issue",
      "action" => "remove",
      "data" => %{"id" => "lin_wh_iss_2"}
    }

    raw_remove = Jason.encode!(remove_payload)
    sig_remove = :hmac |> :crypto.mac(:sha256, secret, raw_remove) |> Base.encode16(case: :lower)

    remove_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", sig_remove)
      |> post(~p"/webhooks/linear/#{ws_id}", raw_remove)

    assert json_response(remove_conn, 200)["received"] == true
    assert Repo.get_by(Issue, external_id: "lin_wh_iss_2") == nil

    # Test remove action for non-existent issue
    remove_nonexistent = %{
      "type" => "Issue",
      "action" => "remove",
      "data" => %{"id" => "lin_nonexistent"}
    }

    raw_nonexistent = Jason.encode!(remove_nonexistent)
    sig_nonexistent = :hmac |> :crypto.mac(:sha256, secret, raw_nonexistent) |> Base.encode16(case: :lower)

    res_nonexistent =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", sig_nonexistent)
      |> post(~p"/webhooks/linear/#{ws_id}", raw_nonexistent)

    assert json_response(res_nonexistent, 200)["received"] == true
  end

  test "ignores non-Issue events gracefully", %{conn: conn} do
    {:ok, %Project{linear_workspace: %LinearWorkspace{id: ws_id, webhook_secret: secret}}} =
      Projects.create_project(system_scope(), %{
        name: "Webhook Project 12910",
        github_repo: "org/webhook-12910",
        github_installation_id: 12_910,
        linear_team_id: "team_wh_3",
        linear_team_key: "P12910",
        default_branch: "main",
        clone_path: "/tmp/repos/webhook-12910",
        linear_workspace: %{
          name: "Webhook Workspace 12910",
          external_id: "lin_ws_webhook_12910",
          token: "lin_api_token_webhook_12910",
          webhook_secret: "whsec_webhook_12910"
        }
      })

    payload = %{"type" => "Comment", "action" => "create", "data" => %{"body" => "hello"}}
    raw = Jason.encode!(payload)
    sig = :hmac |> :crypto.mac(:sha256, secret, raw) |> Base.encode16(case: :lower)

    res_conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("linear-signature", sig)
      |> post(~p"/webhooks/linear/#{ws_id}", raw)

    assert json_response(res_conn, 200)["received"] == true
  end
end
