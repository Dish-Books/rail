defmodule Rail.Domain.Embeds.QaArtifactTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Embeds.QaArtifact

  test "factory/0 builds a valid struct" do
    artifact = QaArtifact.factory()
    assert artifact.name == "test_output.txt"
    assert artifact.kind == :text
    assert artifact.text == "All 12 checks passed"
    assert artifact.url == nil
  end

  test "changeset/2 validates required name and kind enum" do
    changeset = QaArtifact.changeset(%QaArtifact{}, %{})
    refute changeset.valid?
    assert %{name: ["can't be blank"], kind: ["can't be blank"]} = errors_on(changeset)

    invalid_kind = QaArtifact.changeset(%QaArtifact{}, %{"name" => "out.mp3", "kind" => "audio"})
    refute invalid_kind.valid?
    assert %{kind: ["is invalid"]} = errors_on(invalid_kind)

    valid =
      QaArtifact.changeset(%QaArtifact{}, %{
        "name" => "screenshot.png",
        "kind" => "image",
        "url" => "https://linear.app/assets/s1.png"
      })

    assert valid.valid?
    assert Ecto.Changeset.get_field(valid, :kind) == :image
  end

  test "serializes to JSON" do
    artifact = QaArtifact.factory()
    assert {:ok, json} = Jason.encode(artifact)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["name"] == "test_output.txt"
    assert decoded["kind"] == "text"
  end
end
