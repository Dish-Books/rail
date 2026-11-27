defmodule Rail.Git.Actions.BranchFingerprintTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "returns the branch's commit and a digest of its working tree", %{task: task, checkout: checkout} do
    head_sha = String.trim(git!(checkout, ["rev-parse", "HEAD"]))

    assert %{head_sha: ^head_sha, dirty_digest: digest} = Git.branch_fingerprint(task)
    assert byte_size(digest) == 64
  end

  test "returns nil for a task with no repository", %{task: task} do
    File.rm_rf!(Task.repo_path(task))

    assert Git.branch_fingerprint(task) == nil
  end

  test "a new commit advances head_sha", %{task: task, checkout: checkout} do
    fp1 = Git.branch_fingerprint(task)

    File.write!(Path.join(checkout, "new_file.txt"), "committed\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "second commit"])

    assert Git.branch_fingerprint(task).head_sha != fp1.head_sha
  end

  test "uncommitted or untracked changes change dirty_digest", %{task: task, checkout: checkout} do
    fp_clean = Git.branch_fingerprint(task)

    File.write!(Path.join(checkout, "untracked.txt"), "wip\n")
    fp_dirty = Git.branch_fingerprint(task)

    assert fp_clean.head_sha == fp_dirty.head_sha
    assert fp_clean.dirty_digest != fp_dirty.dirty_digest
  end

  test "counts files under .rail in the dirty digest like any other", %{task: task, checkout: checkout} do
    fp_clean = Git.branch_fingerprint(task)

    File.mkdir_p!(Path.join(checkout, ".rail"))
    File.write!(Path.join(checkout, ".rail/settings.json"), "{}\n")

    assert fp_clean.dirty_digest != Git.branch_fingerprint(task).dirty_digest
  end
end
