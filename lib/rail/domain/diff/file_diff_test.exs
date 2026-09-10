defmodule Rail.Domain.Diff.FileDiffTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.FileDiff

  test "new/1 computes path and display_path for modified file" do
    diff =
      FileDiff.new(%{
        old_path: "lib/foo.ex",
        new_path: "lib/foo.ex",
        status: :modified,
        digest: "abc123"
      })

    assert diff.path == "lib/foo.ex"
    assert diff.display_path == "lib/foo.ex"
    assert diff.is_renamed == false
    assert FileDiff.renamed?(diff) == false
    assert diff.status == :modified
  end

  test "new/1 computes renamed display_path with unicode arrow" do
    diff =
      FileDiff.new(
        old_path: "lib/old_name.ex",
        new_path: "lib/new_name.ex",
        status: "renamed",
        digest: "def456"
      )

    assert diff.path == "lib/new_name.ex"
    assert diff.display_path == "lib/old_name.ex → lib/new_name.ex"
    assert diff.is_renamed == true
    assert FileDiff.renamed?(diff) == true
    assert diff.status == :renamed
  end

  test "new/1 handles added file with old_path nil" do
    diff =
      FileDiff.new(%{
        old_path: nil,
        new_path: "lib/new.ex",
        status: "added",
        digest: "ghi789"
      })

    assert diff.path == "lib/new.ex"
    assert diff.display_path == "lib/new.ex"
    assert diff.is_renamed == false
    assert diff.status == :added
  end

  test "new/1 handles deleted file with new_path nil" do
    diff =
      FileDiff.new(%{
        old_path: "lib/deleted.ex",
        new_path: nil,
        status: "deleted",
        digest: "jkl012"
      })

    assert diff.path == "lib/deleted.ex"
    assert diff.display_path == "lib/deleted.ex"
    assert diff.is_renamed == false
    assert diff.status == :deleted
  end

  test "new/1 normalizes string status to atom" do
    assert FileDiff.new(%{status: "unchanged", digest: "1"}).status == :unchanged
    assert FileDiff.new(%{status: "added", digest: "1"}).status == :added
    assert FileDiff.new(%{status: "deleted", digest: "1"}).status == :deleted
    assert FileDiff.new(%{status: "renamed", digest: "1"}).status == :renamed
    assert FileDiff.new(%{status: "anything_else", digest: "1"}).status == :modified
  end

  test "new/1 preserves explicitly passed display_path" do
    diff = FileDiff.new(%{digest: "1", display_path: "Custom Display Path"})
    assert diff.display_path == "Custom Display Path"
  end
end
