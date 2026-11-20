defmodule RailWeb.IntercomWebhookControllerTest do
  use RailWeb.ConnCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Intercom
  alias Rail.Support
  alias Rail.Support.Workers.SyncIntercomConversation

  setup %{project: project} do
    app_id = "app_#{System.unique_integer([:positive])}"
    Req.Test.expect(Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "tok",
        "client_id" => "cid",
        "client_secret" => "whsec_intercom"
      })

    body =
      Jason.encode!(%{
        "type" => "notification_event",
        "app_id" => app_id,
        "topic" => "conversation.user.replied",
        "data" => %{"item" => %{"type" => "conversation", "id" => "9001"}}
      })

    %{workspace: workspace, body: body}
  end

  test "a notice signed with the app's client secret queues a sync of its conversation", %{
    conn: conn,
    workspace: %{id: workspace_id},
    body: body
  } do
    signature = :hmac |> :crypto.mac(:sha, "whsec_intercom", body) |> Base.encode16(case: :upper)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature", "sha1=" <> signature)
      |> post(~p"/webhooks/intercom", body)

    assert %{"received" => true} = json_response(conn, 200)

    assert_enqueued(
      worker: SyncIntercomConversation,
      args: %{"workspace_id" => workspace_id, "external_id" => "9001", "draft" => true}
    )
  end

  test "a notice with a missing or wrong signature is refused", %{conn: conn, body: body} do
    for headers <- [[], [{"x-hub-signature", "sha1=deadbeef"}], [{"x-hub-signature", "sha256=deadbeef"}]] do
      conn =
        Enum.reduce(headers, put_req_header(conn, "content-type", "application/json"), fn {name, value}, conn ->
          put_req_header(conn, name, value)
        end)

      assert %{"error" => "Invalid signature"} = conn |> post(~p"/webhooks/intercom", body) |> json_response(401)
    end

    refute_enqueued(worker: SyncIntercomConversation)
  end

  test "a notice from an app Rail does not know is not found", %{conn: conn} do
    body = Jason.encode!(%{"app_id" => "app_unknown", "topic" => "ping"})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature", "sha1=00")
      |> post(~p"/webhooks/intercom", body)

    assert %{"error" => "Workspace not found"} = json_response(conn, 404)
  end
end
