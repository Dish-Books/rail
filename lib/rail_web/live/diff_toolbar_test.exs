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
        total: 4,
        unsent: 0,
        engineer_running?: false
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

  test "with nothing unsent there is nothing to send", %{toolbar: toolbar} do
    html = render_component(DiffToolbar, toolbar)

    refute html =~ "send-diff-comments"
    refute html =~ "Engineer is"
  end

  test "sends every unsent comment, and says an idle engineer starts at once", %{toolbar: toolbar} do
    html = render_component(DiffToolbar, %{toolbar | unsent: 3})

    assert html |> Floki.parse_fragment!() |> Floki.find("#send-diff-comments") |> Floki.text() =~ "Send 3 comments"
    assert html =~ "Engineer is idle and starts on these at once."
  end

  test "says comments sent to a working engineer wait for its turn to end", %{toolbar: toolbar} do
    html = render_component(DiffToolbar, %{toolbar | unsent: 1, engineer_running?: true})

    assert html |> Floki.parse_fragment!() |> Floki.find("#send-diff-comments") |> Floki.text() |> String.trim() ==
             "Send 1 comment"

    assert html =~ "Engineer is working. These wait until its turn ends."
  end
end
