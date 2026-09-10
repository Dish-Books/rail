defmodule RailWeb.LinearWebhookControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

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
    %LinearWorkspace{id: ws_id} = Repo.insert!(LinearWorkspace.factory())
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
    %LinearWorkspace{id: ws_id, webhook_secret: secret} = workspace = Repo.insert!(LinearWorkspace.factory())

    %Project{id: project_id} =
      Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_wh_1"})

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

  test "handles default project fallback and maps various state types", %{conn: conn} do
    %LinearWorkspace{id: ws_id, webhook_secret: secret} = Repo.insert!(LinearWorkspace.factory())

    %Project{id: project_id} =
      Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_wh_default"})

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

  test "returns ok and skips upsert when workspace has no projects", %{conn: conn} do
    %LinearWorkspace{id: ws_id, webhook_secret: secret} = Repo.insert!(LinearWorkspace.factory())

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
    %LinearWorkspace{id: ws_id, webhook_secret: secret} = Repo.insert!(LinearWorkspace.factory())
    project = Repo.insert!(%{Project.factory() | linear_workspace_id: ws_id, linear_team_id: "team_wh_2"})

    existing_issue =
      Repo.insert!(%{
        Issue.factory()
        | project_id: project.id,
          external_id: "lin_wh_iss_2",
          identifier: "ENG-888",
          title: "Initial Title",
          state: :triage
      })

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
    %LinearWorkspace{id: ws_id, webhook_secret: secret} = Repo.insert!(LinearWorkspace.factory())

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
