defmodule Rail.Git.Actions.BranchFingerprintTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Git.BranchFingerprint

  test "returns fingerprint for clean repository" do
    repo = create_temp_git_repo()

    assert %BranchFingerprint{head_sha: head_sha, dirty_digest: digest} =
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

  test "with ignore_axis: true excludes .axis directory from dirty digest" do
    repo = create_temp_git_repo()
    fp_clean = Git.branch_fingerprint(repo, ignore_axis: true)

    File.mkdir_p!(Path.join(repo, ".axis"))
    File.write!(Path.join(repo, ".axis/settings.json"), "{}\n")

    fp_axis_dirty = Git.branch_fingerprint(repo, ignore_axis: true)

    assert fp_clean.dirty_digest == fp_axis_dirty.dirty_digest
  end
end
