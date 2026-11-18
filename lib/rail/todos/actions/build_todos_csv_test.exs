defmodule Rail.Todos.Actions.BuildTodosCsvTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup do
    n = System.unique_integer([:positive])
    {:ok, user} = Users.register_oauth_user(%{github_id: "gh_csv_#{n}", login: "csv_#{n}", email: "csv_#{n}@example.com"})
    # A fixed clock, so the zone's date and the rows in the file are known.
    stub(DateTime, :utc_now, fn -> ~U[2026-11-18 15:00:00.000000Z] end)
    %{scope: Scope.for_user(user)}
  end

  test "writes today's checked-off to-dos with their links in full and times in the zone given", %{scope: scope} do
    {:ok, typed} = Todos.create_todo(scope, %{"body" => "Answer Product's questions"}, :last)
    {:ok, rail} = Todos.add_link_todo(scope, "/tasks/tsk_1?item=findings&finding=f3", "Ruling Fix scrolls", :last)
    {:ok, outside} = Todos.add_link_todo(scope, "https://github.com/acme/rail/pull/268", "Workflows", :last)
    {:ok, _open} = Todos.create_todo(scope, %{"body" => "Still open"}, :last)

    for {todo, added, done} <- [
          {typed, ~U[2026-11-17 21:40:00Z], ~U[2026-11-18 14:12:00Z]},
          {rail, ~U[2026-11-18 13:55:00Z], ~U[2026-11-18 15:31:00Z]},
          {outside, ~U[2026-11-18 14:02:00Z], ~U[2026-11-18 16:47:00Z]}
        ] do
      Repo.update_all(from(t in Todo, where: t.id == ^todo.id), set: [inserted_at: added, completed_at: done])
    end

    expected =
      <<0xEF, 0xBB, 0xBF>> <>
        ~s("To-do","Link","Added","Checked off"\r\n) <>
        ~s("Answer Product's questions","","2026-11-17 16:40","2026-11-18 09:12"\r\n) <>
        ~s("Ruling Fix scrolls","https://rail.example.com/tasks/tsk_1?item=findings&finding=f3","2026-11-18 08:55","2026-11-18 10:31"\r\n) <>
        ~s("Workflows","https://github.com/acme/rail/pull/268","2026-11-18 09:02","2026-11-18 11:47"\r\n)

    assert {"to-dos-2026-11-18.csv", ^expected} =
             Todos.build_todos_csv(scope, "America/New_York", "https://rail.example.com/")
  end

  test "doubles a quote and keeps a formula as text", %{scope: scope} do
    {:ok, quoted} = Todos.create_todo(scope, %{"body" => ~s(Say "hello")}, :last)
    {:ok, formula} = Todos.create_todo(scope, %{"body" => "=HYPERLINK(\"x\")"}, :last)
    {:ok, minus} = Todos.create_todo(scope, %{"body" => "-1 bug"}, :last)
    {:ok, _quoted} = Todos.complete_todo(scope, quoted)
    {:ok, _formula} = Todos.complete_todo(scope, formula)
    {:ok, _minus} = Todos.complete_todo(scope, minus)

    assert {_filename, <<0xEF, 0xBB, 0xBF, csv::binary>>} =
             Todos.build_todos_csv(scope, "Etc/UTC", "https://rail.example.com")

    assert [_header, ~s("Say ""hello""") <> _q, ~s["'=HYPERLINK(""x"")"] <> _f, ~s("'-1 bug") <> _m, ""] =
             String.split(csv, "\r\n")
  end

  test "names the file for the zone's own date and holds only the header when nothing was checked off",
       %{scope: scope} do
    header_only = <<0xEF, 0xBB, 0xBF>> <> ~s("To-do","Link","Added","Checked off"\r\n)

    assert {"to-dos-2026-11-19.csv", ^header_only} =
             Todos.build_todos_csv(scope, "Pacific/Auckland", "https://rail.example.com")
  end
end
