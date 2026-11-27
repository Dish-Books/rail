defmodule Rail.Git.Utils.FileLinesTest do
  use ExUnit.Case, async: true

  import Rail.Git.Utils.FileLines
  import RailTest.GitHelpers

  setup do
    repo = create_temp_git_repo()
    File.mkdir_p!(Path.join(repo, "lib"))

    %{repo: repo}
  end

  test "reads a file's lines as it was at a revision", %{repo: repo} do
    File.write!(Path.join(repo, "tracked.txt"), "one\ntwo\n")

    assert file_lines(repo, "tracked.txt", "HEAD") == ["one"]
  end

  test "reads a file larger than one read whole", %{repo: repo} do
    File.write!(Path.join(repo, "long.txt"), Enum.map_join(1..20_000, "", &"line #{&1}\n"))
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "long"])

    assert ["line 1" | _rest] = lines = file_lines(repo, "long.txt", "HEAD")
    assert length(lines) == 20_000
    assert List.last(lines) == "line 20000"
  end

  test "a path that is not a file at the revision has no lines to read", %{repo: repo} do
    File.write!(Path.join(repo, "lib/thing.ex"), "thing\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "lib"])

    assert file_lines(repo, "missing.txt", "HEAD") == nil
    assert file_lines(repo, "lib", "HEAD") == nil
    assert file_lines(repo, "lib/thing.ex", "HEAD~1") == nil
  end

  test "an empty file has no lines", %{repo: repo} do
    File.write!(Path.join(repo, "empty.txt"), "")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "empty"])

    assert file_lines(repo, "empty.txt", "HEAD") == []
  end

  # The same split a diff makes, so line numbers agree with the diff's.
  test "splits CRLF and a missing final newline the way a diff does", %{repo: repo} do
    File.write!(Path.join(repo, "crlf.txt"), "one\r\ntwo\r\nthree")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "crlf"])

    assert file_lines(repo, "crlf.txt", "HEAD") == ["one", "two", "three"]
  end
end
