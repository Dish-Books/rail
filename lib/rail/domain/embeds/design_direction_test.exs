defmodule Rail.Domain.Embeds.DesignDirectionTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Embeds.DesignDirection

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
    direction = %DesignDirection{
      key: "direction_a",
      title: "Direction A",
      notes: "Minimalist modern UI",
      still_url: "https://linear.app/assets/still_a.png",
      linear_asset_id: "asset_dir_a"
    }

    assert {:ok, json} = Jason.encode(direction)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["key"] == "direction_a"
    assert decoded["title"] == "Direction A"
  end
end
