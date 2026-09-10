defmodule Rail.Domain.Embeds.QaRowTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Embeds.QaArtifact
  alias Rail.Domain.Embeds.QaRow

  test "factory/0 builds a valid struct" do
    row = QaRow.factory()
    assert row.id == "check_1"
    assert row.check == "Login flow succeeds"
    assert row.result == :pass
    assert row.severity == :blocker
    assert row.caused_by_change == true
    assert row.command == "mix test"
    assert row.exit_code == 0
    assert [%QaArtifact{name: "test_output.txt"}] = row.artifacts
  end

  test "changeset/2 validates required fields and casts embedded artifacts" do
    changeset = QaRow.changeset(%QaRow{}, %{})
    refute changeset.valid?

    assert %{
             id: ["can't be blank"],
             check: ["can't be blank"],
             result: ["can't be blank"],
             severity: ["can't be blank"]
           } = errors_on(changeset)

    invalid_enums =
      QaRow.changeset(%QaRow{}, %{
        "id" => "c2",
        "check" => "Check 2",
        "result" => "unknown_result",
        "severity" => "unknown_severity"
      })

    refute invalid_enums.valid?
    assert %{result: ["is invalid"], severity: ["is invalid"]} = errors_on(invalid_enums)

    valid_attrs = %{
      "id" => "row_2",
      "check" => "Responsive layout adapts",
      "result" => "fail",
      "severity" => "major",
      "caused_by_change" => false,
      "command" => "tool/qa shot",
      "exit_code" => 1,
      "note" => "Overflow on 320px viewport",
      "artifacts" => [
        %{"name" => "shot.png", "kind" => "image", "url" => "https://linear.app/shot.png"}
      ]
    }

    valid = QaRow.changeset(%QaRow{}, valid_attrs)
    assert valid.valid?
    assert Ecto.Changeset.get_field(valid, :result) == :fail
    assert Ecto.Changeset.get_field(valid, :severity) == :major
    assert Ecto.Changeset.get_field(valid, :caused_by_change) == false
    assert [%QaArtifact{name: "shot.png"}] = Ecto.Changeset.get_field(valid, :artifacts)
  end

  test "serializes to JSON" do
    row = QaRow.factory()
    assert {:ok, json} = Jason.encode(row)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["id"] == "check_1"
    assert decoded["result"] == "pass"
    assert decoded["severity"] == "blocker"
    assert [%{"name" => "test_output.txt"}] = decoded["artifacts"]
  end
end
