defmodule RailWeb.LinearWebhookController do
  @moduledoc """
  Receives Linear webhooks: finds the workspace by the payload's
  `organizationId`, checks the HMAC-SHA256 signature against that workspace's
  secret and hands a genuine event to `Rail.Issues`.
  """
  use RailWeb, :controller

  alias Rail.Issues
  alias Rail.Projects

  def handle(conn, params) do
    with {:ok, workspace} <- Projects.get_linear_workspace(external_id: params["organizationId"] || ""),
         true <- valid_signature?(conn, workspace.webhook_secret) do
      Issues.handle_linear_webhook(workspace, params)
      json(conn, %{received: true})
    else
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "Workspace not found"})
      false -> conn |> put_status(:unauthorized) |> json(%{error: "Invalid signature"})
    end
  end

  defp valid_signature?(conn, secret) do
    case get_req_header(conn, "linear-signature") do
      [signature | _rest] ->
        expected = :hmac |> :crypto.mac(:sha256, secret, conn.assigns[:raw_body] || "") |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(expected, String.downcase(signature))

      [] ->
        false
    end
  end
end
