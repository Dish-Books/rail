defmodule RailWeb.Components.SegmentedControlTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.SegmentedControl

  test "presses the selected option and leaves the rest unpressed" do
    html =
      (&SegmentedControl.segmented_control/1)
      |> render_component(
        id: "picker",
        options: [one: "One", two: "Two"],
        selected: :two,
        event: "pick",
        value_name: "choice"
      )
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#picker-one", "aria-pressed") == ["false"]
    assert Floki.attribute(html, "#picker-two", "aria-pressed") == ["true"]
    assert Floki.attribute(html, "#picker-two", "phx-click") == ["pick"]
    assert Floki.attribute(html, "#picker-two", "phx-value-choice") == ["two"]
    assert Floki.attribute(html, "#picker-two", "phx-target") == []
    assert Floki.text(Floki.find(html, "#picker-two")) =~ "Two"
  end

  test "sends the event to a target and names options off their own prefix when given" do
    html =
      (&SegmentedControl.segmented_control/1)
      |> render_component(
        id: "picker",
        option_id: "choice",
        options: [one: "One"],
        selected: :one,
        event: "pick",
        target: "#pane",
        value_name: "choice"
      )
      |> Floki.parse_fragment!()

    assert Floki.attribute(html, "#choice-one", "phx-target") == ["#pane"]
    assert Floki.find(html, "#picker-one") == []
  end
end
