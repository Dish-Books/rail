defmodule Rail.Issues.Schemas.CycleTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Cycle

  @running %Cycle{starts_on: ~D[2026-11-10], ends_on: ~D[2026-11-23]}
  @upcoming %Cycle{starts_on: ~D[2026-11-24], ends_on: ~D[2026-12-07]}

  test "a cycle runs from its first day through its last" do
    assert :upcoming = Cycle.calculate_status(@running, ~D[2026-11-09])
    assert :running = Cycle.calculate_status(@running, ~D[2026-11-10])
    assert :running = Cycle.calculate_status(@running, ~D[2026-11-23])
    assert :ended = Cycle.calculate_status(@running, ~D[2026-11-24])
  end

  test "a running cycle can end today but not before" do
    assert %{valid?: true} = Cycle.dates_changeset(@running, %{"ends_on" => "2026-11-12"}, ~D[2026-11-12])

    assert %{ends_on: ["A running cycle cannot end before today."]} =
             errors_on(Cycle.dates_changeset(@running, %{"ends_on" => "2026-11-11"}, ~D[2026-11-12]))
  end

  test "an upcoming cycle can start today but not before" do
    assert %{valid?: true} = Cycle.dates_changeset(@upcoming, %{"starts_on" => "2026-11-12"}, ~D[2026-11-12])

    assert %{starts_on: ["An upcoming cycle cannot start before today."]} =
             errors_on(Cycle.dates_changeset(@upcoming, %{"starts_on" => "2026-11-11"}, ~D[2026-11-12]))
  end

  test "both dates are needed, and the end cannot come before the start" do
    assert %{starts_on: ["Pick both dates."]} =
             errors_on(Cycle.dates_changeset(@upcoming, %{"starts_on" => ""}, ~D[2026-11-12]))

    assert %{ends_on: ["The end must be on or after the start."]} =
             errors_on(Cycle.changeset(%Cycle{}, %{starts_on: ~D[2026-11-24], ends_on: ~D[2026-11-23]}))
  end

  test "an unestimated issue counts 1 point" do
    assert 1 = Cycle.default_estimate()
  end
end
