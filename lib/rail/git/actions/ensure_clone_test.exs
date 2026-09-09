defmodule Rail.Git.Actions.EnsureCloneTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "clones a repository when destination does not exist" do
    origin_repo = create_temp_git_repo()
    dest_path = Path.join(System.tmp_dir!(), "clone_dest_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dest_path) end)

    assert {:ok, ^dest_path} = Git.ensure_clone(origin_repo, dest_path)
    assert File.dir?(Path.join(dest_path, ".git"))
  end

  test "fetches updates when destination already exists" do
    origin_repo = create_temp_git_repo()
    dest_path = Path.join(System.tmp_dir!(), "clone_dest_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dest_path) end)

    assert {:ok, ^dest_path} = Git.ensure_clone(origin_repo, dest_path)

    # Calling again runs fetch
    assert {:ok, ^dest_path} = Git.ensure_clone(origin_repo, dest_path)
  end

  test "returns error when clone fails" do
    dest_path = Path.join(System.tmp_dir!(), "clone_dest_fail_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dest_path) end)

    assert {:error, reason} = Git.ensure_clone("/nonexistent/repo/url/here", dest_path)
    assert byte_size(reason) > 0
  end

  test "returns error when fetch fails" do
    dest_path = Path.join(System.tmp_dir!(), "fetch_fail_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dest_path, ".git"))
    on_exit(fn -> File.rm_rf(dest_path) end)

    # Empty .git folder without remotes will fail on fetch
    assert {:error, reason} = Git.ensure_clone("dummy_url", dest_path)
    assert byte_size(reason) > 0
  end
end
