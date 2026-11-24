defmodule RailWeb.Components.DueLabelTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Initiatives.Schemas.Initiative
  alias RailWeb.CoreComponents

  test "reads days left before the date, Due today on it, and days late after it in red with a warning" do
    today = ~D[2026-11-23]

    label = fn on ->
      render_component(&CoreComponents.due_label/1, initiative: %Initiative{expected_on: on}, today: today)
    end

    assert label.(~D[2026-12-12]) =~ ~r/pi-calendar-blank.*Dec 12 · 19 days left/s
    assert label.(today) =~ ~r/pi-calendar-check.*Due today/s

    late = label.(~D[2026-11-20])
    assert late =~ ~r/pi-warning-circle.*Nov 20 · 3 days late/s
    assert late =~ "text-red-600"
  end

  test "an initiative with no expected date says so" do
    html =
      render_component(&CoreComponents.due_label/1,
        initiative: %Initiative{expected_on: nil},
        today: ~D[2026-11-23],
        id: "due"
      )

    assert [{"span", [{"id", "due"} | _attrs], _children}] = Floki.parse_fragment!(html)
    assert html =~ "No expected date"
    refute html =~ "left"
  end
end
