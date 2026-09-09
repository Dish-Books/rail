defmodule Rail.Git.BranchFingerprintTest do
  use Rail.DataCase, async: true

  alias Rail.Git.BranchFingerprint

  test "short_head_sha/1 returns first 7 characters or full string if shorter" do
    long = %BranchFingerprint{head_sha: "abcdef1234567890", dirty_digest: "digest1"}
    assert BranchFingerprint.short_head_sha(long) == "abcdef1"

    short = %BranchFingerprint{head_sha: "abc", dirty_digest: "digest2"}
    assert BranchFingerprint.short_head_sha(short) == "abc"
  end
end
