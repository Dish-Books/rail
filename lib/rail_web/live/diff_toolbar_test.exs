defmodule RailWeb.Live.DiffToolbarTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Live.DiffToolbar

  setup do
    fix = %{
      sha: "9c41e07aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      short_sha: "9c41e07",
      parent: "7b19e4c",
      subject: "Fix 4 findings from round 1",
      at: ~U[2026-10-07 16:42:00Z],
      label: "Fix round 1",
      merge?: false,
      merged: nil,
      conflicts: 0,
      files: 6,
      additions: 97,
      deletions: 31
    }

    history = %{base: "main", head: "9c41e07", commits: [fix], files: 14, additions: 612, deletions: 148}

    %{
      fix: fix,
      history: history,
      toolbar: %{
        id: "diff-toolbar",
        target: nil,
        show_file_tree: true,
        picker: %{view: :branch, history: history, dirty?: false, parent: nil},
        wrap: :scroll,
        query: "",
        additions: 10,
        deletions: 3,
        viewed: 1,
        total: 4,
        unsent: 0,
        running?: false,
        agent: "Engineer",
        commentable?: true
      }
    }
  end

  test "leads with the commit picker, which carries the whole branch", %{toolbar: toolbar} do
    html = DiffToolbar |> render_component(toolbar) |> Floki.parse_fragment!()

    assert ["diff-toggle-files", "diff-commit-picker" | _rest] =
             html |> Floki.find("#diff-toolbar button") |> Enum.flat_map(&Floki.attribute(&1, "id"))

    assert html |> Floki.find("#diff-commit-picker") |> Floki.text() =~ "Whole branch"
    assert [] = Floki.find(html, "[data-qa='diff_first_parent']")
  end

  test "a picked commit says which first parent it is shown against", %{toolbar: toolbar, history: history, fix: fix} do
    html =
      DiffToolbar
      |> render_component(%{toolbar | picker: %{view: {:commit, fix.sha}, history: history, dirty?: false, parent: fix}})
      |> Floki.parse_fragment!()

    assert html |> Floki.find("#diff-commit-picker") |> Floki.text() =~ ~r/9c41e07\s+Fix round 1/

    assert html |> Floki.find("[data-qa='diff_first_parent']") |> Floki.text() =~
             ~r/9c41e07 against its first parent\s+7b19e4c/
  end

  test "a merge's view offers no Send, and says why", %{toolbar: toolbar} do
    html = DiffToolbar |> render_component(%{toolbar | unsent: 2, commentable?: false}) |> Floki.parse_fragment!()

    assert [] = Floki.find(html, "#send-diff-comments")
    assert html |> Floki.find("[data-qa='diff_no_comments']") |> Floki.text() =~ "No comments on a merge"
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

    # The click marks the pane loading until its reply, which reads as Sending, and takes no second click.
    assert [send] = html |> Floki.parse_fragment!() |> Floki.find("#send-diff-comments[data-busy-self]")
    assert [click] = Floki.attribute(send, "phx-click")
    assert click =~ ~s("loading":"#diff-pane")
    assert send |> Floki.find("[data-qa='send_diff_comments_sending']") |> Floki.text() =~ "Sending 3"
  end

  test "says comments sent to a working agent wait for its turn to end", %{toolbar: toolbar} do
    html = render_component(DiffToolbar, %{toolbar | unsent: 1, running?: true, agent: "Review lead"})

    assert html |> Floki.parse_fragment!() |> Floki.find("#send-diff-comments > span") |> hd() |> Floki.text() =~
             ~r/\A\s*Send 1 comment\s*\z/

    assert html =~ "Review lead is working. These wait until its turn ends."
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
    working = DiffToolbar |> render_component(%{toolbar | unsent: 2, running?: true}) |> Floki.parse_fragment!()
    idle = DiffToolbar |> render_component(%{toolbar | unsent: 1}) |> Floki.parse_fragment!()

    assert Floki.attribute(working, "#send-diff-comments", "title") == [
             "Engineer is working. These wait until its turn ends."
           ]

    assert Floki.attribute(idle, "#send-diff-comments", "title") == ["Engineer is idle and starts on these at once."]
    assert working |> Floki.find("[data-qa='send_noun']") |> Floki.text() == " comments"
    assert idle |> Floki.find("[data-qa='send_noun']") |> Floki.text() == " comment"
  end
end
