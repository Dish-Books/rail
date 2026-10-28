defmodule RailWeb.Components.StageSequenceTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.StageSequence

  test "every step on runs Plan, Implement and Review and skips nothing" do
    html = render_component(&StageSequence.stage_sequence/1, id: "seq", skipped: [])

    assert html =~ "Plan › Implement › Review"
    refute html =~ "Skips"
  end

  test "the steps skipped are named in their usual order" do
    html = render_component(&StageSequence.stage_sequence/1, id: "seq", skipped: [:design, :product])

    assert html =~ "Plan › Implement › Review"
    assert html =~ "Skips product and design"

    html = render_component(&StageSequence.stage_sequence/1, id: "seq", skipped: [:demo, :architect, :design])
    assert html =~ "Skips design, architect and demo"

    html = render_component(&StageSequence.stage_sequence/1, id: "seq", skipped: [:demo])
    assert html =~ "Skips demo"
  end

  test "all three Plan steps off leave Plan out and read as plan, on one line when asked" do
    html =
      render_component(&StageSequence.stage_sequence/1,
        id: "seq",
        skipped: [:product, :design, :architect, :demo],
        layout: :inline
      )

    assert html |> Floki.parse_fragment!() |> Floki.text() |> String.split() |> Enum.join(" ") ==
             "· Implement › Review · skips plan and demo"
  end
end
