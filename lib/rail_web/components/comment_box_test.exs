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
end
