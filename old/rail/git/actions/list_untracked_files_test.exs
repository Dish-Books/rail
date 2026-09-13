defmodule Rail.Git.Actions.ListUntrackedFilesTest do
  use Rail.DataCase, async: true

  alias Rail.Git

  test "lists untracked files and excludes ignored files" do
    repo = create_temp_git_repo()

    File.write!(Path.join(repo, "new_file.txt"), "hello\n")
    File.write!(Path.join(repo, ".gitignore"), "ignored_dir/\n")
    File.mkdir_p!(Path.join(repo, "ignored_dir"))
    File.write!(Path.join(repo, "ignored_dir/hidden.txt"), "secret\n")

    untracked = Git.list_untracked_files(repo)
    assert "new_file.txt" in untracked
    assert ".gitignore" in untracked
    refute "ignored_dir/hidden.txt" in untracked
  end

  test "returns empty list on non-git directory" do
    temp_dir = System.tmp_dir!()
    loose = Path.join(temp_dir, "loose_dir_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert Git.list_untracked_files(loose) == []
  end
end
