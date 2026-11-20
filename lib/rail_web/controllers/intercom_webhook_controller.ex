defmodule RailWeb.IntercomWebhookController do
  use RailWeb, :controller

  alias Rail.Support

  def handle(conn, params) do
    with {:ok, workspace} <- Support.get_intercom_workspace(external_id: to_string(params["app_id"])),
         true <- valid_signature?(conn, workspace.client_secret) do
      _queued = Support.handle_intercom_webhook(workspace, params)
      json(conn, %{received: true})
    else
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "Workspace not found"})
      false -> conn |> put_status(:unauthorized) |> json(%{error: "Invalid signature"})
    end
  end

  # Intercom signs the raw body with the app's client secret, HMAC-SHA1.
  defp valid_signature?(conn, secret) do
    case get_req_header(conn, "x-hub-signature") do
      ["sha1=" <> signature | _rest] ->
        expected = :hmac |> :crypto.mac(:sha, secret, conn.assigns[:raw_body] || "") |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(expected, String.downcase(signature))

      _missing ->
        false
    end
  end
end
