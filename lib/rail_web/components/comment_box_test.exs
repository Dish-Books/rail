defmodule RailWeb.Components.CommentBoxTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.CommentBox

  test "renders the label, the typed body, Cancel and Save comment wired to the events given" do
    html =
      render_component(&CommentBox.comment_box/1,
        id: "box",
        body_id: "box-body",
        qa: "plan_comment",
        label: "h2",
        body: "Half a thought",
        submit: "save_it",
        change: "change_it",
        cancel: "cancel_it",
        target: nil,
        heading: [%{inner_block: fn _changed, _arg -> "The heading" end}]
      )

    [form] = html |> Floki.parse_fragment!() |> Floki.find("form#box")

    assert Floki.attribute(form, "data-qa") == ["plan_comment_form"]
    assert Floki.attribute(form, "phx-submit") == ["save_it"]
    assert Floki.attribute(form, "phx-change") == ["change_it"]
    assert Floki.text(form) =~ "The heading"
    assert [{"textarea", _attrs, ["Half a thought"]} = body] = Floki.find(form, "textarea#box-body")
    assert Floki.attribute(body, "aria-label") == ["Comment on h2"]
    assert Floki.attribute(body, "phx-keydown") == ["cancel_it"]
    assert Floki.attribute(body, "phx-key") == ["Escape"]
    assert form |> Floki.find("[data-qa='plan_comment_cancel']") |> Floki.attribute("phx-click") == ["cancel_it"]
    assert form |> Floki.find("[data-qa='plan_comment_save']") |> Floki.text() =~ "Save comment"
  end

  # A box in a narrow column, as the screen view's, gives its hint a line of its own rather than cut it.
  test "a narrow box puts its hint on a line of its own" do
    attrs = [
      id: "box",
      body_id: "box-body",
      qa: "screen_comment",
      label: "Toolbar",
      submit: "save_it",
      change: "change_it",
      cancel: "cancel_it",
      target: nil
    ]

    narrow = (&CommentBox.comment_box/1) |> render_component([{:narrow, true} | attrs]) |> Floki.parse_fragment!()
    wide = (&CommentBox.comment_box/1) |> render_component(attrs) |> Floki.parse_fragment!()

    assert [_hint] = Floki.find(narrow, ".flex-wrap > span.basis-full")
    assert [] = Floki.find(wide, ".basis-full")
  end
end
