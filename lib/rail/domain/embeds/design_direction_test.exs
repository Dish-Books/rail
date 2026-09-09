defmodule Rail.Domain.Embeds.DesignDirectionTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Embeds.DesignDirection

  test "factory/0 builds a valid struct" do
    direction = DesignDirection.factory()
    assert direction.key == "direction_a"
    assert direction.title == "Direction A"
    assert direction.notes == "Minimalist modern UI"
    assert direction.still_url == "https://linear.app/assets/still_a.png"
    assert direction.linear_asset_id == "asset_dir_a"
  end

  test "changeset/2 validates required fields" do
    changeset = DesignDirection.changeset(%DesignDirection{}, %{})
    refute changeset.valid?
    assert %{key: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)

    valid_changeset =
      DesignDirection.changeset(%DesignDirection{}, %{
        "key" => "dir_b",
        "title" => "Direction B",
        "notes" => "Dark theme",
        "still_url" => "https://linear.app/b.png",
        "linear_asset_id" => "asset_b"
      })

    assert valid_changeset.valid?
  end

  test "serializes to JSON" do
    direction = DesignDirection.factory()
    assert {:ok, json} = Jason.encode(direction)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["key"] == "direction_a"
    assert decoded["title"] == "Direction A"
  end
end
