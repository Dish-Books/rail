defmodule Rail.Domain.Enums.ArtifactKindTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Enums.ArtifactKind

  test "all/0 and values/0 contain text and image" do
    expected = [:text, :image]
    assert ArtifactKind.all() == expected
    assert ArtifactKind.values() == expected
  end

  test "label/1 returns correct display labels" do
    assert ArtifactKind.label(:text) == "Text"
    assert ArtifactKind.label(:image) == "Image"
    assert ArtifactKind.label(:invalid) == nil
  end

  test "predicates test artifact kind" do
    assert ArtifactKind.text?(:text)
    refute ArtifactKind.text?(:image)
    refute ArtifactKind.text?(:invalid)

    assert ArtifactKind.image?(:image)
    refute ArtifactKind.image?(:text)
    refute ArtifactKind.image?(:invalid)
  end

  test "cast and dump work as expected" do
    assert ArtifactKind.cast("text") == {:ok, :text}
    assert ArtifactKind.cast("image") == {:ok, :image}
    assert ArtifactKind.dump(:text) == {:ok, "text"}
    assert ArtifactKind.load("image") == {:ok, :image}
  end
end
