defmodule Rail.Pipeline.Types.ViewedDiffFilesTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Types.ViewedDiffFiles

  test "type/0 returns :map" do
    assert ViewedDiffFiles.type() == :map
  end

  test "cast/1 supports maps, lists, nil, and rejects invalid types" do
    assert {:ok, %{"lib/foo.ex" => "hash1"}} = ViewedDiffFiles.cast(%{"lib/foo.ex" => "hash1"})
    assert {:ok, %{"lib/foo.ex" => ""}} = ViewedDiffFiles.cast(["lib/foo.ex"])
    assert {:ok, %{}} = ViewedDiffFiles.cast(nil)
    assert :error = ViewedDiffFiles.cast("invalid")
    assert :error = ViewedDiffFiles.cast(123)
  end

  test "load/1 supports maps, lists, nil, and rejects invalid types" do
    assert {:ok, %{"lib/foo.ex" => "hash1"}} = ViewedDiffFiles.load(%{"lib/foo.ex" => "hash1"})
    assert {:ok, %{"lib/foo.ex" => ""}} = ViewedDiffFiles.load(["lib/foo.ex"])
    assert {:ok, %{}} = ViewedDiffFiles.load(nil)
    assert :error = ViewedDiffFiles.load(456)
  end

  test "dump/1 supports maps, lists, nil, and rejects invalid types" do
    assert {:ok, %{"lib/foo.ex" => "hash1"}} = ViewedDiffFiles.dump(%{"lib/foo.ex" => "hash1"})
    assert {:ok, %{"lib/foo.ex" => ""}} = ViewedDiffFiles.dump(["lib/foo.ex"])
    assert {:ok, %{}} = ViewedDiffFiles.dump(nil)
    assert :error = ViewedDiffFiles.dump(:invalid)
  end
end
