defmodule Rail.Git.Actions.FileLinesTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "reads lines from disk when no rev provided" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "disk_file.txt"), "hello\nworld\n")

    assert Git.file_lines(repo, "disk_file.txt") == ["hello", "world"]
  end

  test "reads lines from git rev" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "tracked.txt"), "committed line\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "update tracked"])

    # Now mutate file on disk
    File.write!(Path.join(repo, "tracked.txt"), "mutated line on disk\n")

    # From disk
    assert Git.file_lines(repo, "tracked.txt") == ["mutated line on disk"]

    # From revision HEAD
    assert Git.file_lines(repo, "tracked.txt", rev: "HEAD") == ["committed line"]
  end

  test "returns nil when file does not exist on disk or in git" do
    repo = create_temp_git_repo()

    assert Git.file_lines(repo, "nonexistent.txt") == nil
    assert Git.file_lines(repo, "nonexistent.txt", rev: "HEAD") == nil
    assert Git.file_lines(repo, "tracked.txt", rev: "nonexistent_rev_xyz") == nil
  end

  test "handles empty file correctly" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "empty.txt"), "")

    assert Git.file_lines(repo, "empty.txt") == []
  end

  test "reads lines from file without trailing newline" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "notrail.txt"), "first\nsecond")

    assert Git.file_lines(repo, "notrail.txt") == ["first", "second"]
  end

  test "returns nil when relative path points to a directory" do
    repo = create_temp_git_repo()
    File.mkdir_p!(Path.join(repo, "some_dir"))

    assert Git.file_lines(repo, "some_dir") == nil
  end
end
