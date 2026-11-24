defmodule Rail.Initiatives.Schemas.InitiativeTest do
  use Rail.DataCase, async: true

  alias Rail.Initiatives.Schemas.Initiative

  test "percent done counts Done tickets out of the counted ones, to the nearest, 100 only with all Done" do
    assert Initiative.calculate_percent(%Initiative{done_count: 1, ticket_count: 3}) == 33
    assert Initiative.calculate_percent(%Initiative{done_count: 2, ticket_count: 3}) == 67
    assert Initiative.calculate_percent(%Initiative{done_count: 199, ticket_count: 200}) == 99
    assert Initiative.calculate_percent(%Initiative{done_count: 2, ticket_count: 2}) == 100
    assert Initiative.calculate_percent(%Initiative{done_count: 0, ticket_count: 0}) == 0
  end

  test "the expected date reads as days left, due today or days late, and nothing with none" do
    today = ~D[2026-11-23]

    assert Initiative.calculate_due_text(%Initiative{expected_on: ~D[2026-12-12]}, today) == "19 days left"
    assert Initiative.calculate_due_text(%Initiative{expected_on: ~D[2026-11-24]}, today) == "1 day left"
    assert Initiative.calculate_due_text(%Initiative{expected_on: today}, today) == "due today"
    assert Initiative.calculate_due_text(%Initiative{expected_on: ~D[2026-11-22]}, today) == "1 day late"
    assert Initiative.calculate_due_text(%Initiative{expected_on: ~D[2026-11-20]}, today) == "3 days late"
    assert Initiative.calculate_due_text(%Initiative{expected_on: nil}, today) == nil
    assert Initiative.calculate_due(%Initiative{expected_on: ~D[2026-11-20]}, today) == {:late, 3}
  end

  test "the name is trimmed and required, a blank date clears it, and blank notes stay empty" do
    changeset =
      Initiative.changeset(%Initiative{expected_on: ~D[2026-12-12], notes: "Old"}, %{
        "name" => "  Credo exclusions  ",
        "expected_on" => "",
        "notes" => ""
      })

    assert %Ecto.Changeset{valid?: true, changes: %{name: "Credo exclusions", expected_on: nil, notes: ""}} = changeset

    assert %{name: ["can't be blank"]} = errors_on(Initiative.changeset(%Initiative{}, %{"name" => "   "}))

    assert %{name: ["should be at most 200 character(s)"]} =
             errors_on(Initiative.changeset(%Initiative{}, %{"name" => String.duplicate("a", 201)}))
  end
end
