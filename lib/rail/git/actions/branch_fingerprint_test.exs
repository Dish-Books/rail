defmodule Rail.Git.Actions.BranchFingerprintTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "returns fingerprint for clean repository" do
    repo = create_temp_git_repo()

    assert %{head_sha: head_sha, dirty_digest: digest} =
             Git.branch_fingerprint(repo)

    assert byte_size(head_sha) == 40
    assert byte_size(digest) == 64
  end

  test "returns nil on invalid or non-git path" do
    temp_dir = System.tmp_dir!()
    loose = Path.join(temp_dir, "non_git_fingerprint_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert Git.branch_fingerprint(loose) == nil
  end

  # What CI's commit is read from, in a checkout whose .git the sandbox can write.
  test "runs no fsmonitor or hook a checkout names" do
    repo = create_temp_git_repo()
    ran = Path.join(System.tmp_dir!(), "fingerprint_ran_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(ran) end)
    File.mkdir_p!(ran)
    git!(repo, ["config", "core.fsmonitor", "touch #{ran}/fsmonitor; false"])
    git!(repo, ["config", "core.hooksPath", ran])
    File.write!(Path.join(ran, "post-index-change"), "#!/bin/sh\ntouch #{ran}/hook\n")
    File.chmod!(Path.join(ran, "post-index-change"), 0o755)
    File.write!(Path.join(repo, "tracked.txt"), "two\n")

    assert %{head_sha: _head, dirty_digest: _digest} = Git.branch_fingerprint(repo)
    assert File.ls!(ran) == ["post-index-change"]
  end

  test "new commit advances head_sha" do
    repo = create_temp_git_repo()
    fp1 = Git.branch_fingerprint(repo)

    File.write!(Path.join(repo, "new_file.txt"), "committed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "second commit"])

    fp2 = Git.branch_fingerprint(repo)

    assert fp1.head_sha != fp2.head_sha
  end

  test "uncommitted or untracked changes change dirty_digest" do
    repo = create_temp_git_repo()
    fp_clean = Git.branch_fingerprint(repo)

    File.write!(Path.join(repo, "untracked.txt"), "wip\n")
    fp_dirty = Git.branch_fingerprint(repo)

    assert fp_clean.head_sha == fp_dirty.head_sha
    assert fp_clean.dirty_digest != fp_dirty.dirty_digest
  end

  test "counts files under .rail in the dirty digest like any other" do
    repo = create_temp_git_repo()
    fp_clean = Git.branch_fingerprint(repo)

    File.mkdir_p!(Path.join(repo, ".rail"))
    File.write!(Path.join(repo, ".rail/settings.json"), "{}\n")

    assert fp_clean.dirty_digest != Git.branch_fingerprint(repo).dirty_digest
  end
end
