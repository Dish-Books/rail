defmodule Rail.Pipeline.Schemas.QaChecklistTest do
  use Rail.DataCase, async: true

  alias Ecto.Changeset
  alias Rail.Pipeline.Schemas.QaChecklist

  test "how far through the pass is, counting anything that has been run" do
    checklist =
      %QaChecklist{}
      |> QaChecklist.changeset(%{
        checks: [
          %{key: "bill-saves", title: "A bill saves", outcome: "pass"},
          %{key: "plaid", title: "The Plaid callback", outcome: "skipped"},
          %{key: "totals", title: "The totals agree"}
        ]
      })
      |> Changeset.apply_action!(:insert)

    assert QaChecklist.progress(checklist) == {2, 3}
  end

  test "a checklist that checks nothing is not a checklist" do
    changeset = QaChecklist.changeset(%QaChecklist{}, %{checks: []})

    refute changeset.valid?
    assert %{checks: ["a checklist needs at least one check"]} = errors_on(changeset)
  end

  # A row is marked off by its key, so a second row sharing one would never be
  # reachable.
  test "two rows cannot share a key" do
    changeset =
      QaChecklist.changeset(%QaChecklist{}, %{
        checks: [
          %{key: "bill-saves", title: "A bill saves"},
          %{key: "bill-saves", title: "A bill saves on reload"}
        ]
      })

    refute changeset.valid?
    assert %{checks: ["every check needs its own key"]} = errors_on(changeset)
  end

  test "a row that is not usable takes the checklist with it" do
    changeset = QaChecklist.changeset(%QaChecklist{}, %{checks: [%{title: "A bill saves"}]})

    refute changeset.valid?
    assert %{checks: [%{key: ["can't be blank"]}]} = errors_on(changeset)
  end
end
