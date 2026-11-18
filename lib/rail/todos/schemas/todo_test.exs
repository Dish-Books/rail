defmodule Rail.Todos.Schemas.TodoTest do
  use Rail.DataCase, async: true

  alias Rail.Todos.Schemas.Todo

  test "a typed to-do is trimmed and takes only its text" do
    changeset = Todo.changeset(%Todo{}, %{"body" => "  Upload the bills  ", "url" => "/tasks/tsk_1", "position" => 9})

    assert %Ecto.Changeset{valid?: true, changes: %{body: "Upload the bills"} = changes} = changeset
    refute Map.has_key?(changes, :url)
    refute Map.has_key?(changes, :position)
  end

  test "a blank or over-long to-do is refused" do
    assert %{body: ["can't be blank"]} = errors_on(Todo.changeset(%Todo{}, %{"body" => "   "}))

    assert %{body: ["should be at most 500 character(s)"]} =
             errors_on(Todo.changeset(%Todo{}, %{"body" => String.duplicate("x", 501)}))

    assert %Ecto.Changeset{valid?: true} = Todo.changeset(%Todo{}, %{"body" => String.duplicate("x", 500)})
  end

  test "a dropped link is a Rail path or an http(s) address" do
    for url <- ["/tasks/tsk_1?item=findings&finding=F3", "/", "https://github.com/acme/rail/pull/1", "http://example.com"] do
      assert %Ecto.Changeset{valid?: true} = Todo.link_changeset(%Todo{}, %{body: "Link", url: url})
    end

    for url <- ["//evil.example.com/x", "javascript:alert(1)", "mailto:ana@example.com", "https:///nohost", "tasks/1"] do
      assert %{url: ["has invalid format"]} = errors_on(Todo.link_changeset(%Todo{}, %{body: "Link", url: url}))
    end

    assert %{url: ["can't be blank"]} = errors_on(Todo.link_changeset(%Todo{}, %{body: "Link"}))
  end
end
