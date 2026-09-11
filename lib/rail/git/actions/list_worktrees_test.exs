defmodule Rail.Git.Actions.ListWorktreesTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Git.WorktreeInfo
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  test "lists root worktree and additional worktrees" do
    repo = create_temp_git_repo()
    wt_path = Path.join(repo, ".worktrees/wt1")
    assert {:ok, ^wt_path} = Git.get_or_create_worktree(%Project{clone_path: repo, default_branch: "main"}, %Task{worktree_path: wt_path, worktree_name: "feature-wt1"})

    worktrees = Git.list_worktrees(repo)

    assert length(worktrees) == 2

    root = Enum.find(worktrees, fn wt -> File.stat!(wt.path).inode == File.stat!(repo).inode end)
    assert %WorktreeInfo{branch: "main", is_bare: false} = root
    assert byte_size(root.commit_sha) == 40

    wt1 = Enum.find(worktrees, fn wt -> File.stat!(wt.path).inode == File.stat!(wt_path).inode end)
    assert %WorktreeInfo{branch: "feature-wt1", is_bare: false} = wt1
    assert byte_size(wt1.commit_sha) == 40
  end

  test "returns empty list on non-git path" do
    temp_dir = System.tmp_dir!()
    loose = Path.join(temp_dir, "loose_wt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    assert Git.list_worktrees(loose) == []
  end
end
