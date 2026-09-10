defmodule Rail.Git.Actions.RecentCommitsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Git.CommitInfo

  test "returns recent commits with commit info structs" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "second.txt"), "second\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "second commit message"])

    commits = Git.recent_commits(repo)

    assert length(commits) == 2
    [c1, c2] = commits

    assert %CommitInfo{
             message: "second commit message",
             author: "Rail Test"
           } = c1

    assert byte_size(c1.sha) == 40
    assert byte_size(c1.short_sha) >= 7
    assert byte_size(c1.date) > 0

    assert %CommitInfo{
             message: "initial commit",
             author: "Rail Test"
           } = c2
  end

  test "respects limit option" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "c2.txt"), "c2\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "c2"])

    File.write!(Path.join(repo, "c3.txt"), "c3\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "c3"])

    commits = Git.recent_commits(repo, limit: 2)
    assert length(commits) == 2
    assert hd(commits).message == "c3"
  end

  test "returns empty list on non-git directory" do
    temp_dir = System.tmp_dir!()
    loose = Path.join(temp_dir, "loose_commits_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert Git.recent_commits(loose) == []
  end
end
