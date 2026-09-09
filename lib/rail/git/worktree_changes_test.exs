defmodule Rail.Git.WorktreeChangesTest do
  use Rail.DataCase, async: true

  alias Rail.Git.ChangedFile
  alias Rail.Git.WorktreeChanges

  test "calculates additions, deletions, and empty? correctly" do
    empty_changes = %WorktreeChanges{filter: "uncommitted", files: []}
    assert WorktreeChanges.additions(empty_changes) == 0
    assert WorktreeChanges.deletions(empty_changes) == 0
    assert WorktreeChanges.empty?(empty_changes)

    file1 = %ChangedFile{file_path: "a.txt", additions: 5, deletions: 2}
    file2 = %ChangedFile{file_path: "b.txt", additions: 10, deletions: 3}
    changes = %WorktreeChanges{filter: "main", files: [file1, file2]}

    assert WorktreeChanges.additions(changes) == 15
    assert WorktreeChanges.deletions(changes) == 5
    refute WorktreeChanges.empty?(changes)
  end
end
