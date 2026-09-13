defmodule Rail.Git.Actions.SynthesizeUntrackedDiffTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.DiffHunk
  alias Rail.Domain.Diff.DiffLine
  alias Rail.Domain.Diff.FileDiff
  alias Rail.Git

  test "synthesizes unified diff for text file" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "scratch.txt"), "hello\nworld\n")

    diff = Git.synthesize_untracked_diff(repo, "scratch.txt")

    assert String.contains?(diff, "diff --git a/scratch.txt b/scratch.txt")
    assert String.contains?(diff, "new file (untracked)")
    assert String.contains?(diff, "@@ -0,0 +1,2 @@")
    assert String.contains?(diff, "+hello\n+world\n")

    assert [
             %FileDiff{
               path: "scratch.txt",
               status: :added,
               additions: 2,
               deletions: 0,
               hunks: [
                 %DiffHunk{
                   lines: [
                     %DiffLine{kind: :added, text: "hello"},
                     %DiffLine{kind: :added, text: "world"}
                   ]
                 }
               ]
             }
           ] = Git.parse_unified_diff(diff)
  end

  test "synthesizes diff for binary file" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "photo.jpg"), <<0xFF, 0xD8, 0x00, 0xE0>>)

    diff = Git.synthesize_untracked_diff(repo, "photo.jpg")

    assert String.contains?(diff, "diff --git a/photo.jpg b/photo.jpg")
    assert String.contains?(diff, "new file (untracked)")
    assert String.contains?(diff, "Binary file photo.jpg differs")

    assert [
             %FileDiff{
               path: "photo.jpg",
               is_binary: true,
               status: :added
             }
           ] = Git.parse_unified_diff(diff)
  end

  test "synthesizes diff for empty text file" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "empty.txt"), "")

    diff = Git.synthesize_untracked_diff(repo, "empty.txt")
    assert String.contains?(diff, "@@ -0,0 +1,0 @@")
  end

  test "returns empty string when file does not exist" do
    repo = create_temp_git_repo()
    assert Git.synthesize_untracked_diff(repo, "missing.txt") == ""
  end

  test "synthesizes diff for text file without trailing newline" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "notrail.txt"), "single line without newline")

    diff = Git.synthesize_untracked_diff(repo, "notrail.txt")
    assert String.contains?(diff, "@@ -0,0 +1,1 @@")
    assert String.contains?(diff, "+single line without newline\n")
  end
end
