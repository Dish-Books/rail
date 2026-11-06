defmodule RailWeb.Components.StageSequenceTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.IssueStage
  alias RailWeb.Components.StageSequence

  test "every step on runs Plan, Implement and Review and skips nothing" do
    html = render_component(&StageSequence.stage_sequence/1, id: "seq", skipped: [])

    assert html |> Floki.parse_fragment!() |> Floki.find("#seq-stages") |> Floki.text() == "Plan › Implement › Review"
    refute html =~ "Skips"
  end

  test "a custom stage reads by its name in its place, set apart from the built-ins" do
    stages = [
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check."},
      %IssueStage{stage: :review}
    ]

    html = render_component(&StageSequence.stage_sequence/1, id: "seq", skipped: [], stages: stages)
    fragment = Floki.parse_fragment!(html)

    assert fragment |> Floki.find("#seq-stages") |> Floki.text() == "Plan › Implement › License check › Review"
    assert fragment |> Floki.find("#seq-stages .font-semibold") |> Floki.text() == "License check"
  end

  test "the steps skipped are named in their usual order" do
    html = render_component(&StageSequence.stage_sequence/1, id: "seq", skipped: [:design, :product])

    assert html |> Floki.parse_fragment!() |> Floki.find("#seq-stages") |> Floki.text() == "Plan › Implement › Review"
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
