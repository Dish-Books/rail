defmodule RailWeb.Live.DiffToolbarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Live.DiffToolbar

  setup do
    %{
      toolbar: %{
        id: "diff-toolbar",
        target: nil,
        show_file_tree: true,
        filter: :branch,
        query: "",
        additions: 10,
        deletions: 3,
        viewed: 1,
        total: 4
      }
    }
  end

  test "counts what the diff added and took away, and how much of it is read", %{toolbar: toolbar} do
    html = render_component(DiffToolbar, toolbar)

    assert html =~ "+10"
    assert html =~ "-3"
    assert html =~ "1/4"
    assert html =~ "width: 25%;"
  end

  test "reads as nothing read when there is nothing to read", %{toolbar: toolbar} do
    assert render_component(DiffToolbar, %{toolbar | viewed: 0, total: 0}) =~ "width: 0%;"
  end
end
