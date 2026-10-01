defmodule Rail.Git.Actions.ContentFingerprintTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "names the commit and digests what is on top of it" do
    repo = create_temp_git_repo()

    head_sha = String.trim(git!(repo, ["rev-parse", "HEAD"]))

    assert %{head_sha: ^head_sha, content_digest: digest} = Git.content_fingerprint(repo)
    assert byte_size(digest) == 64
  end

  # `git status` reads " M" both times, which is what the status digest stops at.
  test "rewriting a file already modified changes the digest" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "feature.ex"), "committed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "feature"])

    File.write!(Path.join(repo, "feature.ex"), "first edit\n")
    first = Git.content_fingerprint(repo)
    File.write!(Path.join(repo, "feature.ex"), "second edit\n")

    assert Git.content_fingerprint(repo).content_digest != first.content_digest
  end

  test "rewriting an untracked file changes the digest" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "new.ex"), "first\n")
    first = Git.content_fingerprint(repo)
    File.write!(Path.join(repo, "new.ex"), "second\n")

    assert Git.content_fingerprint(repo).content_digest != first.content_digest
  end

  test "the same tree reads the same digest" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "new.ex"), "same\n")

    assert Git.content_fingerprint(repo) == Git.content_fingerprint(repo)
  end

  test "what agents write under .rail/ is left out" do
    repo = create_temp_git_repo()
    clean = Git.content_fingerprint(repo)

    File.mkdir_p!(Path.join(repo, ".rail"))
    File.write!(Path.join([repo, ".rail", "report.json"]), "{}")

    assert Git.content_fingerprint(repo) == clean
  end

  test "a directory git cannot read has no fingerprint" do
    loose = Path.join(System.tmp_dir!(), "non_git_content_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert Git.content_fingerprint(loose) == nil
  end
end
