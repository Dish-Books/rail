defmodule Rail.Pipeline.Schemas.QaCheckTest do
  use Rail.DataCase, async: true

  alias Ecto.Changeset
  alias Rail.Pipeline.Schemas.QaCheck

  test "a check arrives with nothing decided about it" do
    changeset = QaCheck.changeset(%QaCheck{}, %{key: "bill-saves", title: "A bill saves and comes back on reload"})

    assert changeset.valid?
    assert Changeset.get_field(changeset, :outcome) == :pending
  end

  test "a check needs a key and a title" do
    changeset = QaCheck.changeset(%QaCheck{}, %{criterion: "the bill saves"})

    refute changeset.valid?
    assert %{key: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)
  end

  # The key is what marks a row off later, and it travels through a tool call as
  # text, so anything a person would not type twice the same way is refused.
  test "a key is lowercase and hyphenated" do
    changeset = QaCheck.changeset(%QaCheck{}, %{key: "Bill Saves", title: "A bill saves"})

    refute changeset.valid?
    assert %{key: ["has invalid format"]} = errors_on(changeset)
  end

  test "every outcome has a name, and only one of them means it has not been run" do
    assert QaCheck.outcomes() == [:pending, :pass, :fail, :skipped]

    assert Enum.map(QaCheck.outcomes(), &QaCheck.outcome_label/1) == [
             "Not yet run",
             "Passed",
             "Failed",
             "Skipped"
           ]

    assert Enum.map(QaCheck.outcomes(), &QaCheck.run?(%QaCheck{outcome: &1})) == [false, true, true, true]
  end
end
