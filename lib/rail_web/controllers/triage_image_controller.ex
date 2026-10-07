defmodule RailWeb.TriageImageController do
  @moduledoc false
  use RailWeb, :controller

  alias Rail.Triage

  def show(conn, %{"message_id" => message_id, "file_id" => file_id}) do
    case Triage.get_triage_image(conn.assigns.current_scope, message_id, file_id) do
      {:ok, mimetype, body} ->
        conn
        |> put_resp_content_type(mimetype, nil)
        |> put_resp_header("cache-control", "private, max-age=3600")
        # Someone posted the file, so an SVG opened on its own must not run script as Rail.
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox")
        |> send_resp(200, body)

      {:error, _unavailable} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
