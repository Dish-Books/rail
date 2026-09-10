defmodule Rail.Pipeline.Actions.ExpandDiffGapTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline

  test "slices lines from start_line to end_line from disk when diff_rev is nil" do
    repo = create_temp_git_repo()
    content = Enum.map_join(1..20, "\n", fn i -> "line #{i}" end) <> "\n"
    File.write!(Path.join(repo, "sample.txt"), content)

    task = create_test_task(%{worktree_path: repo})

    assert {"sample.txt:0", ["line 5", "line 6", "line 7"]} =
             Pipeline.expand_diff_gap(task, "sample.txt", 0, 5, 7, nil)
  end

  test "reads lines from git rev HEAD when diff_rev is provided" do
    repo = create_temp_git_repo()
    content = Enum.map_join(1..10, "\n", fn i -> "rev line #{i}" end) <> "\n"
    File.write!(Path.join(repo, "committed.txt"), content)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "add committed"])

    task = create_test_task(%{worktree_path: repo})

    assert {"committed.txt:1", ["rev line 2", "rev line 3"]} =
             Pipeline.expand_diff_gap(task, "committed.txt", 1, 2, 3, "HEAD")
  end

  test "returns empty list when file lines cannot be read or file does not exist" do
    repo = create_temp_git_repo()
    task = create_test_task(%{worktree_path: repo})

    assert {"missing.txt:0", []} =
             Pipeline.expand_diff_gap(task, "missing.txt", 0, 1, 5, nil)
  end

  test "returns empty list when worktree_path is nil" do
    task = create_test_task(%{worktree_path: nil})

    assert {"any.txt:0", []} =
             Pipeline.expand_diff_gap(task, "any.txt", 0, 1, 5, nil)
  end
end
