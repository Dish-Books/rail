defmodule RailWeb.TodoExportControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])

    {:ok, mine} =
      Users.register_oauth_user(%{github_id: "gh_exp_m#{n}", login: "exp_m#{n}", email: "exp_m#{n}@example.com"})

    {:ok, theirs} =
      Users.register_oauth_user(%{github_id: "gh_exp_t#{n}", login: "exp_t#{n}", email: "exp_t#{n}@example.com"})

    %{mine: mine, theirs: theirs}
  end

  test "downloads the signed-in person's checked-off to-dos for today as UTF-8 CSV", %{
    conn: conn,
    mine: mine,
    theirs: theirs
  } do
    scope = Scope.for_user(mine)
    {:ok, todo} = Todos.create_todo(scope, %{"body" => "Café ☕ run"}, :last)
    {:ok, _done} = Todos.complete_todo(scope, todo)
    {filename, _csv} = Todos.build_todos_csv(scope, "Asia/Tokyo", "https://rail.example.com")

    conn = conn |> log_in_user(mine) |> get(~p"/todos/export?#{[tz: "Asia/Tokyo"]}")

    assert body = response(conn, 200)
    assert ["text/csv; charset=utf-8"] = get_resp_header(conn, "content-type")
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(attachment; filename="#{filename}")
    assert ["private, no-cache"] = get_resp_header(conn, "cache-control")
    assert String.starts_with?(body, <<0xEF, 0xBB, 0xBF>> <> ~s("To-do","Link","Added","Checked off"\r\n"Café ☕ run"))

    theirs_conn = build_conn() |> log_in_user(theirs) |> get(~p"/todos/export?#{[tz: "Asia/Tokyo"]}")
    assert response(theirs_conn, 200) == <<0xEF, 0xBB, 0xBF>> <> ~s("To-do","Link","Added","Checked off"\r\n)
  end

  test "sends a signed-out visitor to sign in", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/todos/export")) =~ "/sign-in"
  end
end
