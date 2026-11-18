defmodule RailWeb.Components.TodosPanelTest do
  use RailWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Todos
  alias Rail.Todos.Schemas.Todo
  alias Rail.Users

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_panel_#{n}", login: "panel_#{n}", email: "panel_#{n}@example.com"})

    %{conn: log_in_user(conn, user), user: user, scope: Scope.for_user(user)}
  end

  test "lists open and checked-off rows together by position, each with a handle", %{conn: conn, scope: scope} do
    {:ok, %Todo{id: first_id}} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :last)
    {:ok, %Todo{id: last_id}} = Todos.create_todo(scope, %{"body" => "Last"}, :last)
    {:ok, %Todo{id: done_id}} = Todos.complete_todo(scope, done)
    {:ok, _moved} = Todos.move_todo(scope, done, last_id)

    conn = put_connect_params(conn, %{"todos_open" => true, "time_zone" => "Etc/UTC"})
    {:ok, view, _html} = live(conn, ~p"/")
    doc = view |> render() |> Floki.parse_document!()

    assert [^first_id, ^done_id, ^last_id] = Floki.attribute(doc, "#todos-list [data-todo-row]", "data-todo-row")
    assert [_first, _done, _last] = Floki.find(doc, "#todos-list [data-todo-handle]")
    assert ["false", "true", "false"] = Floki.attribute(doc, "#todos-list [data-qa=todo_check]", "aria-checked")
    assert doc |> Floki.find("#todo-#{done_id} .line-through") |> Floki.text() |> String.trim() == "Done"
    assert [] = Floki.find(doc, "#todo-#{first_id} .line-through")
  end

  # Checked off two hours ago, before the person's midnight an hour ago, so it was yesterday for them.
  test "leaves out a to-do checked off before midnight in the browser's zone", %{conn: conn, scope: scope} do
    now = DateTime.utc_now()
    offset = Integer.mod(1 - now.hour, 24)
    offset = if offset > 14, do: offset - 24, else: offset
    zone = if offset > 0, do: "Etc/GMT-#{offset}", else: "Etc/GMT+#{-offset}"

    {:ok, yesterday} = Todos.create_todo(scope, %{"body" => "Yesterday's"}, :last)
    {:ok, today} = Todos.create_todo(scope, %{"body" => "Today's"}, :last)
    {:ok, _yesterday} = Todos.complete_todo(scope, yesterday)
    {:ok, _today} = Todos.complete_todo(scope, today)
    Repo.update_all(from(t in Todo, where: t.id == ^yesterday.id), set: [completed_at: DateTime.shift(now, hour: -2)])

    conn = put_connect_params(conn, %{"todos_open" => true, "time_zone" => zone})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#todo-#{today.id}")
    refute has_element?(view, "#todo-#{yesterday.id}")
    assert view |> element("#todos-done-today") |> render() =~ "checked off today"
    assert view |> element("#todos-export") |> render() =~ "tz=Etc%2FGMT"
  end

  test "with only checked-off rows, shows them with no empty note and no count", %{conn: conn, scope: scope} do
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :last)
    {:ok, _done} = Todos.complete_todo(scope, done)

    conn = put_connect_params(conn, %{"todos_open" => true, "time_zone" => "Etc/UTC"})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#todo-#{done.id}")
    refute has_element?(view, "#todos-empty")
    refute has_element?(view, "#todos-count")
    assert view |> element("#todos-sheet-count") |> render() =~ "0 to-dos"
    assert view |> element("#todos-done-today") |> render() =~ ~r/1<\/span>\s*checked off today/
    assert has_element?(view, "#todos-export")
  end

  test "checking off moves a row below the open ones and counts it, and unchecking leaves it where it stands",
       %{conn: conn, scope: scope} do
    {:ok, %Todo{id: first_id} = first} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, %Todo{id: second_id}} = Todos.create_todo(scope, %{"body" => "Second"}, :last)

    conn = put_connect_params(conn, %{"todos_open" => true, "time_zone" => "Etc/UTC"})
    {:ok, view, _html} = live(conn, ~p"/")
    assert view |> element("#todos-count") |> render() =~ "2"
    assert view |> element("#todos-done-today") |> render() =~ "Nothing checked off today"

    view |> element("#todo-check-#{first_id}") |> render_click()

    doc = view |> render() |> Floki.parse_document!()
    assert [^second_id, ^first_id] = Floki.attribute(doc, "#todos-list [data-todo-row]", "data-todo-row")
    assert ["true"] = Floki.attribute(doc, "#todo-check-#{first_id}", "aria-checked")
    assert view |> element("#todos-count") |> render() =~ "1"
    assert view |> element("#todos-done-today") |> render() =~ ~r/1<\/span>\s*checked off today/

    # The row already shows checked, so a second, late "check" for it changes nothing.
    view |> with_target("#todos-panel") |> render_click("check", %{"todo_id" => first_id})
    assert %Todo{position: 1} = Repo.reload!(first)

    view |> element("#todo-check-#{first_id}") |> render_click()

    doc = view |> render() |> Floki.parse_document!()
    assert [^second_id, ^first_id] = Floki.attribute(doc, "#todos-list [data-todo-row]", "data-todo-row")
    assert ["false"] = Floki.attribute(doc, "#todo-check-#{first_id}", "aria-checked")
    assert view |> element("#todos-count") |> render() =~ "2"

    view |> with_target("#todos-panel") |> render_click("uncheck", %{"todo_id" => first_id})
    assert %Todo{completed_at: nil} = Repo.reload!(first)
  end

  test "a move lands in front of the row it names, and a move it cannot make, or a malformed one, changes nothing",
       %{conn: conn, scope: scope} do
    {:ok, %Todo{id: first_id}} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, %Todo{id: second_id}} = Todos.create_todo(scope, %{"body" => "Second"}, :last)
    {:ok, %Todo{id: third_id}} = Todos.create_todo(scope, %{"body" => "Third"}, :last)

    conn = put_connect_params(conn, %{"todos_open" => true, "time_zone" => "Etc/UTC"})
    {:ok, view, _html} = live(conn, ~p"/")
    drop = element(view, "#todos-drop")

    render_hook(drop, "move", %{"todo_id" => third_id, "before_id" => first_id})
    render_hook(drop, "move", %{"todo_id" => first_id, "before_id" => nil})
    render_hook(drop, "move", %{"todo_id" => "tdo_gone", "before_id" => nil})
    render_hook(drop, "move", %{"todo_id" => second_id})
    render_hook(drop, "drop_link", %{"url" => "/sandboxes"})
    render_hook(drop, "drop_text", %{"text" => 5, "before_id" => nil})

    doc = view |> render() |> Floki.parse_document!()
    assert [^third_id, ^second_id, ^first_id] = Floki.attribute(doc, "#todos-list [data-todo-row]", "data-todo-row")
    assert [_first, _second, _third] = Todos.list_todos(scope)
  end

  test "the To-dos button opens the panel and puts it away, as Close does, with no Escape binding",
       %{conn: conn} do
    {:ok, view, _html} = live(put_connect_params(conn, %{"time_zone" => "Etc/UTC"}), ~p"/")
    refute has_element?(view, "#todos-sheet")
    assert has_element?(view, "#todos-button[aria-expanded=false]")

    view |> element("#todos-button") |> render_click()
    assert has_element?(view, "#todos-sheet")
    assert has_element?(view, "#todos-button[aria-expanded=true]")
    assert has_element?(view, "#todo-body-0[phx-mounted]")
    assert_push_event(view, "todos-open", %{open: true})
    refute view |> element("#todos-sheet") |> render() =~ "phx-window-keydown"
    refute view |> element("#todos-sheet") |> render() =~ "phx-key"

    view |> element("#todos-close") |> render_click()
    refute has_element?(view, "#todos-sheet")
    assert_push_event(view, "todos-open", %{open: false})

    view |> element("#todos-button") |> render_click()
    assert_push_event(view, "todos-open", %{open: true})
    view |> element("#todos-button") |> render_click()
    refute has_element?(view, "#todos-sheet")
    assert_push_event(view, "todos-open", %{open: false})
  end

  test "adding a to-do puts it below the last open one and brings a new, empty field", %{conn: conn, scope: scope} do
    {:ok, %Todo{id: open_id}} = Todos.create_todo(scope, %{"body" => "Open"}, :last)
    {:ok, done} = Todos.create_todo(scope, %{"body" => "Done"}, :last)
    {:ok, %Todo{id: done_id}} = Todos.complete_todo(scope, done)

    {:ok, view, _html} = live(put_connect_params(conn, %{"time_zone" => "Etc/UTC"}), ~p"/")
    view |> element("#todos-button") |> render_click()

    view |> form("#todo-form-0", todo: %{body: "Typed"}) |> render_change()
    view |> form("#todo-form-0", todo: %{body: "Typed"}) |> render_submit()

    [%Todo{id: typed_id, body: "Typed"}] = Enum.reject(Todos.list_todos(scope), &(&1.id == open_id))
    doc = view |> render() |> Floki.parse_document!()
    assert [^open_id, ^typed_id, ^done_id] = Floki.attribute(doc, "#todos-list [data-todo-row]", "data-todo-row")
    refute has_element?(view, "#todo-form-0")
    assert [] = Floki.attribute(doc, "#todo-body-1", "value")
    assert has_element?(view, "#todo-body-1[phx-mounted]")
  end

  test "a long to-do wraps rather than running off the side", %{conn: conn, scope: scope} do
    {:ok, todo} = Todos.create_todo(scope, %{"body" => String.duplicate("unbroken", 60)}, :last)

    {:ok, view, _html} = live(put_connect_params(conn, %{"todos_open" => true}), ~p"/")

    assert [class] =
             view
             |> render()
             |> Floki.parse_document!()
             |> Floki.attribute("#todo-#{todo.id} [data-qa=todo_body_text]", "class")

    assert "[overflow-wrap:anywhere]" in String.split(class)
  end

  test "a link dropped in front of the second row lands there and keeps what was typed",
       %{conn: conn, scope: scope} do
    {:ok, %Todo{id: first_id}} = Todos.create_todo(scope, %{"body" => "First"}, :last)
    {:ok, %Todo{id: second_id}} = Todos.create_todo(scope, %{"body" => "Second"}, :last)

    conn = put_connect_params(conn, %{"todos_open" => true, "time_zone" => "Etc/UTC"})
    {:ok, view, _html} = live(conn, ~p"/")

    view |> form("#todo-form-0", todo: %{body: "Half-typed"}) |> render_change()

    view
    |> element("#todos-drop")
    |> render_hook("drop_link", %{"url" => "/sandboxes", "text" => "dragged", "before_id" => second_id})

    view
    |> element("#todos-drop")
    |> render_hook("drop_text", %{"text" => "Selected words", "before_id" => nil})

    view
    |> element("#todos-drop")
    |> render_hook("drop_link", %{"url" => "https://example.com/a", "text" => "Outside", "before_id" => nil})

    doc = view |> render() |> Floki.parse_document!()

    assert [^first_id, sandboxes_id, ^second_id, _text_id, outside_id] =
             Floki.attribute(doc, "#todos-list [data-todo-row]", "data-todo-row")

    assert ["/sandboxes"] = Floki.attribute(doc, "#todo-#{sandboxes_id} a[data-qa=todo_link]", "href")
    assert ["_blank"] = Floki.attribute(doc, "#todo-#{outside_id} a[data-qa=todo_link]", "target")
    assert doc |> Floki.find("#todo-#{sandboxes_id}") |> Floki.text() =~ "Sandboxes"
    assert ["Half-typed"] = Floki.attribute(doc, "#todo-body-0", "value")
  end

  test "a change in one tab reaches the other without a reload, footer and all", %{conn: conn, scope: scope} do
    {:ok, %Todo{id: first_id}} = Todos.create_todo(scope, %{"body" => "First"}, :last)

    conn = put_connect_params(conn, %{"todos_open" => true, "time_zone" => "Etc/UTC"})
    {:ok, one, _html} = live(conn, ~p"/")
    {:ok, two, _html} = live(conn, ~p"/")

    one |> form("#todo-form-0", todo: %{body: "Second"}) |> render_submit()
    [_first, %Todo{id: second_id}] = Todos.list_todos(scope)

    eventually(fn ->
      assert [^first_id, ^second_id] =
               two
               |> render()
               |> Floki.parse_document!()
               |> Floki.attribute("#todos-list [data-todo-row]", "data-todo-row")
    end)

    one |> element("#todos-drop") |> render_hook("move", %{"todo_id" => second_id, "before_id" => first_id})

    eventually(fn ->
      assert [^second_id, ^first_id] =
               two
               |> render()
               |> Floki.parse_document!()
               |> Floki.attribute("#todos-list [data-todo-row]", "data-todo-row")
    end)

    one |> element("#todo-check-#{second_id}") |> render_click()

    eventually(fn ->
      assert has_element?(two, "#todo-check-#{second_id}[aria-checked=true]")
      assert two |> element("#todos-done-today") |> render() =~ ~r/1<\/span>\s*checked off today/
    end)

    one |> element("#todo-check-#{second_id}") |> render_click()

    eventually(fn ->
      assert has_element?(two, "#todo-check-#{second_id}[aria-checked=false]")
      assert two |> element("#todos-done-today") |> render() =~ "Nothing checked off today"
    end)
  end

  test "another person sees none of my to-dos, and a project pick leaves mine as they were",
       %{conn: conn, scope: scope, project: project} do
    {:ok, %Todo{id: mine_id}} = Todos.create_todo(scope, %{"body" => "Mine"}, :last)

    n = System.unique_integer([:positive])

    {:ok, other} =
      Users.register_oauth_user(%{github_id: "gh_panel_o#{n}", login: "panel_o#{n}", email: "panel_o#{n}@example.com"})

    other_conn = build_conn() |> log_in_user(other) |> put_connect_params(%{"todos_open" => true})
    {:ok, theirs, _html} = live(other_conn, ~p"/")
    assert has_element?(theirs, "#todos-empty")
    refute has_element?(theirs, "#todo-#{mine_id}")

    conn = conn |> init_test_session(%{selected_project_id: project.id}) |> put_connect_params(%{"todos_open" => true})
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#todo-#{mine_id}")
  end

  test "with nothing open or checked off, says so with the field still there, and ignores a blank line",
       %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(put_connect_params(conn, %{"time_zone" => "Etc/UTC"}), ~p"/")
    view |> element("#todos-button") |> render_click()

    assert has_element?(view, "#todos-empty", "Nothing to do. Type one, or drop a link here.")
    assert has_element?(view, "#todo-body-0")
    assert view |> element("#todos-done-today") |> render() =~ "Nothing checked off today"
    refute has_element?(view, "#todos-export")

    view |> form("#todo-form-0", todo: %{body: "   "}) |> render_submit()

    assert [] = Todos.list_todos(scope)
    assert has_element?(view, "#todos-empty")
    refute has_element?(view, "#todos-list")
    assert has_element?(view, "#todo-body-0[value='   ']")
  end
end
