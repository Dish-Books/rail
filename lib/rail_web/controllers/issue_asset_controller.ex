defmodule RailWeb.IssueAssetController do
  @moduledoc false
  use RailWeb, :controller

  alias Rail.Issues

  def show(conn, %{"issue_id" => issue_id, "path" => segments}) do
    with {:ok, issue} <- Issues.get_issue(issue_id),
         {:ok, content_type, body} <- Issues.get_asset(issue, asset_path(segments, conn.query_string)) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> send_resp(200, body)
    else
      _missing -> send_resp(conn, 404, "Not found")
    end
  end

  # Linear signs some of its file URLs, so the query has to travel with the path.
  defp asset_path(segments, ""), do: Enum.join(segments, "/")
  defp asset_path(segments, query), do: "#{Enum.join(segments, "/")}?#{query}"
end
