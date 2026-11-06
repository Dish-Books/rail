defmodule RailWeb.Components.DesignCommentControlTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias RailWeb.Components.DesignCommentControl

  test "off, it reads Comment with its C key and is not pressed" do
    html = render_component(&DesignCommentControl.design_comment_control/1, commenting: false, target: nil)
    [button] = html |> Floki.parse_fragment!() |> Floki.find("#design-comment-toggle")

    assert Floki.text(button) =~ ~r/Comment\s*C/
    assert Floki.attribute(button, "aria-pressed") == ["false"]
    assert Floki.attribute(button, "phx-click") == ["toggle_commenting"]
    refute html =~ "Click an element"
  end

  test "on, it reads Commenting, pressed, with its Esc key and what to do" do
    html = render_component(&DesignCommentControl.design_comment_control/1, commenting: true, target: nil)
    [button] = html |> Floki.parse_fragment!() |> Floki.find("#design-comment-toggle")

    assert Floki.text(button) =~ ~r/Commenting\s*Esc/
    assert Floki.attribute(button, "aria-pressed") == ["true"]
    assert html =~ "Click an element to comment on it."
  end

  test "disabled, it shows the reason it is given and takes no click" do
    html =
      render_component(&DesignCommentControl.design_comment_control/1,
        commenting: false,
        disabled_reason: "Pick a design to comment on it.",
        target: nil
      )

    [button] = html |> Floki.parse_fragment!() |> Floki.find("#design-comment-toggle")

    assert Floki.attribute(button, "disabled") != []
    assert Floki.attribute(button, "phx-click") == []

    assert html |> Floki.parse_fragment!() |> Floki.find("#design-comment-hint") |> Floki.text() =~
             "Pick a design to comment on it."
  end

  test "what it is given sits at the row's right end, after the hint, and the toggle stays as it was" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <DesignCommentControl.design_comment_control
        commenting={false}
        disabled_reason="Pick a design to comment on it."
        target={nil}
      >
        Use this design
      </DesignCommentControl.design_comment_control>
      """)

    assert [toggle, hint, right_end] = html |> Floki.parse_fragment!() |> Floki.find("#design-comment-control > *")

    assert Floki.attribute(toggle, "id") == ["design-comment-toggle"]
    assert Floki.attribute(toggle, "disabled") != []
    assert Floki.attribute(hint, "id") == ["design-comment-hint"]
    assert Floki.text(right_end) =~ "Use this design"
    assert [class] = Floki.attribute(right_end, "class")
    assert class =~ "ml-auto"
    assert class =~ "shrink-0"
  end
end
