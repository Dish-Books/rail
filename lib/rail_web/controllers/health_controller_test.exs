defmodule RailWeb.HealthControllerTest do
  use RailWeb.ConnCase, async: true

  test "GET /_health returns 200 ok", %{conn: conn} do
    conn = get(conn, ~p"/_health")
    assert text_response(conn, 200) == "ok"
  end
end
