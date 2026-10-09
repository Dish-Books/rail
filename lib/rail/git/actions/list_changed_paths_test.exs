defmodule Rail.Git.Actions.ListChangedPathsTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers

  alias Rail.Git

  test "every path changed, deleted or untracked since HEAD, sorted" do
    repo = create_temp_git_repo()
    File.write!(Path.join(repo, "gone.txt"), "soon gone\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "add gone"])

    File.write!(Path.join(repo, "tracked.txt"), "edited\n")
    File.rm!(Path.join(repo, "gone.txt"))
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join([repo, "lib", "new file.ex"]), "new\n")
    File.write!(Path.join(repo, "staged.ex"), "staged\n")
    git!(repo, ["add", "staged.ex"])

    assert Git.list_changed_paths(repo) == ["gone.txt", "lib/new file.ex", "staged.ex", "tracked.txt"]
  end

  test "a clean worktree, or one git cannot read, has nothing changed" do
    assert Git.list_changed_paths(create_temp_git_repo()) == []
    assert Git.list_changed_paths(System.tmp_dir!()) == []
  end
end
