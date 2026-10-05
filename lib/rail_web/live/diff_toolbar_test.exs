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
        wrap: :scroll,
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

    # A second click before the first is answered would find nothing left to send.
    assert [_disabled_while_sending] =
             html |> Floki.parse_fragment!() |> Floki.find("#send-diff-comments[phx-disable-with]")
  end

  test "says comments sent to a working engineer wait for its turn to end", %{toolbar: toolbar} do
    html = render_component(DiffToolbar, %{toolbar | unsent: 1, engineer_running?: true})

    assert html |> Floki.parse_fragment!() |> Floki.find("#send-diff-comments") |> Floki.text() |> String.trim() ==
             "Send 1 comment"

    assert html =~ "Engineer is working. These wait until its turn ends."
  end

  test "long lines scroll or wrap, as the reader chose", %{toolbar: toolbar} do
    scroll = DiffToolbar |> render_component(toolbar) |> Floki.parse_fragment!()
    wrap = DiffToolbar |> render_component(%{toolbar | wrap: :wrap}) |> Floki.parse_fragment!()

    assert Floki.attribute(scroll, "#diff-wrap", "title") == ["Long lines"]
    assert Floki.attribute(scroll, "#diff-wrap-scroll", "aria-pressed") == ["true"]
    assert Floki.attribute(scroll, "#diff-wrap-wrap", "aria-pressed") == ["false"]
    assert Floki.attribute(wrap, "#diff-wrap-scroll", "aria-pressed") == ["false"]
    assert Floki.attribute(wrap, "#diff-wrap-wrap", "aria-pressed") == ["true"]
  end

  # The choice is the browser's, so the hook applies it and tells the stage.
  test "the wrap control is the browser's, told to the stage", %{toolbar: toolbar} do
    html = DiffToolbar |> render_component(%{toolbar | target: "#engineer-stage"}) |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#diff-wrap", "phx-hook") == ["DiffWrap"]
    assert Floki.attribute(html, "#diff-wrap", "data-target") == ["#engineer-stage"]
    assert Floki.attribute(html, "#diff-wrap-wrap", "phx-click") == ["select_diff_wrap"]
    assert Floki.attribute(html, "#diff-wrap-wrap", "phx-value-wrap") == ["wrap"]
    assert Floki.attribute(html, "#diff-wrap-wrap", "phx-target") == ["#engineer-stage"]
  end

  # A narrow toolbar hides the hint and the word after the count.
  test "Send says what the hint says, and its noun is what a narrow toolbar drops", %{toolbar: toolbar} do
    working = DiffToolbar |> render_component(%{toolbar | unsent: 2, engineer_running?: true}) |> Floki.parse_fragment!()
    idle = DiffToolbar |> render_component(%{toolbar | unsent: 1}) |> Floki.parse_fragment!()

    assert Floki.attribute(working, "#send-diff-comments", "title") == [
             "Engineer is working. These wait until its turn ends."
           ]

    assert Floki.attribute(idle, "#send-diff-comments", "title") == ["Engineer is idle and starts on these at once."]
    assert working |> Floki.find("[data-qa='send_noun']") |> Floki.text() == " comments"
    assert idle |> Floki.find("[data-qa='send_noun']") |> Floki.text() == " comment"
  end
end
