defmodule Rail.Support.Schemas.ItemTest do
  use Rail.DataCase, async: true

  alias Rail.Support.Schemas.Item

  setup do
    %{
      attrs: %{
        "key" => "sesame",
        "position" => 1,
        "kind" => "bug",
        "title" => "Sesame missing from the allergen sheet",
        "verdict" => "confirmed",
        "evidence" => [%{"file" => "lib/a.ex", "lines" => "4", "excerpt" => "x", "holds" => true}],
        "assumptions" => [%{"text" => "Tahini is sesame."}],
        "issue_title" => "The allergen sheet lists sesame for tahini",
        "issue_priority" => "urgent",
        "issue_estimate" => 2
      }
    }
  end

  test "a drafted item is valid with its evidence and assumptions", %{attrs: attrs} do
    assert %Ecto.Changeset{
             valid?: true,
             changes: %{
               kind: :bug,
               verdict: :confirmed,
               issue_priority: :urgent,
               evidence: [%Ecto.Changeset{changes: %{file: "lib/a.ex"}}],
               assumptions: [%Ecto.Changeset{changes: %{text: "Tahini is sesame."}}]
             }
           } = Item.agent_changeset(%Item{}, attrs)
  end

  test "an item with no ticket and no drafted title is refused", %{attrs: attrs} do
    changeset = Item.agent_changeset(%Item{}, Map.delete(attrs, "issue_title"))
    assert %{issue_title: ["can't be blank"]} = errors_on(changeset)
  end

  test "an item an existing ticket tracks needs no drafted title", %{attrs: attrs} do
    assert %Ecto.Changeset{valid?: true} =
             Item.agent_changeset(%Item{}, attrs |> Map.delete("issue_title") |> Map.put("existing_issue_id", "iss_1"))
  end

  test "a verdict that does not fit the kind, an unknown verdict and an off-scale estimate are refused", %{attrs: attrs} do
    assert %{verdict: ["does not fit the kind"]} =
             errors_on(Item.agent_changeset(%Item{}, %{attrs | "verdict" => "built"}))

    assert %{verdict: ["is invalid"]} = errors_on(Item.agent_changeset(%Item{}, %{attrs | "verdict" => "maybe"}))
    assert %{issue_estimate: ["is invalid"]} = errors_on(Item.agent_changeset(%Item{}, %{attrs | "issue_estimate" => 4}))
  end

  test "an item is forwardable when untracked, unforwarded and titled" do
    assert Item.forwardable?(%Item{issue_title: "Title"})
    refute Item.forwardable?(%Item{issue_title: " "})
    refute Item.forwardable?(%Item{issue_title: nil})
    refute Item.forwardable?(%Item{issue_title: "Title", existing_issue_id: "iss_1"})
    refute Item.forwardable?(%Item{issue_title: "Title", forwarded_at: ~U[2026-11-20 10:00:00Z]})
  end

  test "tracked when an existing ticket covers it" do
    assert Item.tracked?(%Item{existing_issue_id: "iss_1"})
    refute Item.tracked?(%Item{})
  end
end
