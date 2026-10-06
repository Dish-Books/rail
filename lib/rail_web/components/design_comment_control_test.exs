defmodule RailWeb.Components.DesignCommentControlTest do
  use RailWeb.ConnCase, async: true

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
end
