defmodule Rail.Git.Utils.FileLinesTest do
  use ExUnit.Case, async: true

  import Rail.Git.Utils.FileLines
  import RailTest.GitHelpers

  setup do
    repo = create_temp_git_repo()
    File.mkdir_p!(Path.join(repo, "lib"))

    %{repo: repo}
  end

  test "reads a file's lines as it is in the worktree", %{repo: repo} do
    File.write!(Path.join(repo, "tracked.txt"), "one\ntwo\n")

    assert file_lines(repo, "tracked.txt") == ["one", "two"]
  end

  test "reads a file's lines as it was at a revision", %{repo: repo} do
    File.write!(Path.join(repo, "tracked.txt"), "one\ntwo\n")

    assert file_lines(repo, "tracked.txt", "HEAD") == ["one"]
  end

  test "a file that is not there has no lines to read", %{repo: repo} do
    assert file_lines(repo, "missing.txt") == nil
    assert file_lines(repo, "lib") == nil
  end

  test "a path that is not a file at the revision has no lines to read", %{repo: repo} do
    File.write!(Path.join(repo, "lib/thing.ex"), "thing\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "lib"])

    assert file_lines(repo, "missing.txt", "HEAD") == nil
    assert file_lines(repo, "lib", "HEAD") == nil
    assert file_lines(repo, "lib/thing.ex", "HEAD~1") == nil
  end

  test "a path that climbs out of the worktree has no lines to read", %{repo: repo} do
    outside = repo <> "_outside.txt"
    File.write!(outside, "secret\n")
    on_exit(fn -> File.rm(outside) end)

    assert file_lines(repo, "../" <> Path.basename(outside)) == nil
    assert file_lines(repo, "lib/../../" <> Path.basename(outside)) == nil
  end

  test "an empty file has no lines", %{repo: repo} do
    File.write!(Path.join(repo, "empty.txt"), "")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "empty"])

    assert file_lines(repo, "empty.txt") == []
    assert file_lines(repo, "empty.txt", "HEAD") == []
  end

  # The same split a diff makes, so line numbers agree with the diff's.
  test "splits CRLF and a missing final newline the way a diff does", %{repo: repo} do
    File.write!(Path.join(repo, "crlf.txt"), "one\r\ntwo\r\nthree")

    assert file_lines(repo, "crlf.txt") == ["one", "two", "three"]
  end
end
