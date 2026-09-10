defmodule Rail.Git.Actions.HeadShaTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.ToolEnv

  test "returns short HEAD sha for valid repository" do
    repo = create_temp_git_repo()

    sha = Git.head_sha(repo)
    assert byte_size(sha) >= 7

    {expected, 0} = ToolEnv.run("git", ["rev-parse", "--short", "HEAD"], cd: repo)
    assert sha == String.trim(expected)
  end

  test "returns nil for non-git path" do
    temp_dir = System.tmp_dir!()
    loose = Path.join(temp_dir, "not_git_sha_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert Git.head_sha(loose) == nil
  end
end
