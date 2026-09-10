defmodule Rail.Domain.Embeds.CliAccountGroupTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Embeds.CliAccountGroup

  test "factory/0 builds a valid struct" do
    group = CliAccountGroup.factory()
    assert group.name == "Gemini Models"
    assert group.count == 3
    assert group.details == %{"window" => "5-hour", "remaining_percent" => 100.0}
  end

  test "changeset/2 validates required name and non-negative count" do
    changeset = CliAccountGroup.changeset(%CliAccountGroup{}, %{})
    refute changeset.valid?
    assert %{name: ["can't be blank"]} = errors_on(changeset)

    invalid_count =
      CliAccountGroup.changeset(%CliAccountGroup{}, %{
        "name" => "Group A",
        "count" => -1
      })

    refute invalid_count.valid?
    assert %{count: ["must be greater than or equal to 0"]} = errors_on(invalid_count)

    valid =
      CliAccountGroup.changeset(%CliAccountGroup{}, %{
        "name" => "Claude Models",
        "count" => 2,
        "details" => %{"tier" => "enterprise"}
      })

    assert valid.valid?
    assert Ecto.Changeset.get_field(valid, :name) == "Claude Models"
    assert Ecto.Changeset.get_field(valid, :count) == 2
    assert Ecto.Changeset.get_field(valid, :details) == %{"tier" => "enterprise"}
  end

  test "serializes to JSON" do
    group = CliAccountGroup.factory()
    assert {:ok, json} = Jason.encode(group)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["name"] == "Gemini Models"
    assert decoded["count"] == 3
  end
end
