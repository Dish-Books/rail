defmodule Rail.Git.Actions.ContentFingerprintTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "names the commit and digests what is on top of it", %{task: task, checkout: checkout} do
    head_sha = String.trim(git!(checkout, ["rev-parse", "HEAD"]))

    assert %{head_sha: ^head_sha, content_digest: digest} = Git.content_fingerprint(task)
    assert byte_size(digest) == 64
  end

  # The status digest reads the file as modified both times.
  test "rewriting a file already modified changes the digest", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "tracked.txt"), "first edit\n")
    first = Git.content_fingerprint(task)
    File.write!(Path.join(checkout, "tracked.txt"), "second edit\n")

    assert Git.content_fingerprint(task).content_digest != first.content_digest
  end

  test "rewriting an untracked file changes the digest", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "new.ex"), "first\n")
    first = Git.content_fingerprint(task)
    File.write!(Path.join(checkout, "new.ex"), "second\n")

    assert Git.content_fingerprint(task).content_digest != first.content_digest
  end

  test "the same tree reads the same digest", %{task: task, checkout: checkout} do
    File.write!(Path.join(checkout, "new.ex"), "same\n")

    assert Git.content_fingerprint(task) == Git.content_fingerprint(task)
  end

  test "what agents write under .rail/ is left out", %{task: task, checkout: checkout} do
    clean = Git.content_fingerprint(task)

    File.mkdir_p!(Path.join(checkout, ".rail"))
    File.write!(Path.join([checkout, ".rail", "report.json"]), "{}")

    assert Git.content_fingerprint(task) == clean
  end

  test "a task with no repository has no fingerprint", %{task: task} do
    File.rm_rf!(Task.repo_path(task))

    assert Git.content_fingerprint(task) == nil
  end
end
