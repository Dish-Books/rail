defmodule RailWeb.TodoExportController do
  use RailWeb, :controller

  alias Rail.Todos

  def export(conn, params) do
    {filename, csv} = Todos.build_todos_csv(conn.assigns.current_scope, params["tz"], url(~p"/"))

    conn
    |> put_resp_header("cache-control", "private, no-cache")
    |> send_download({:binary, csv}, filename: filename, content_type: "text/csv", charset: "utf-8")
  end
end
