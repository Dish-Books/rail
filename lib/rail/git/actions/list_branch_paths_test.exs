defmodule Rail.Git.Actions.ListBranchPathsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    remote = create_temp_git_repo(prefix: "rail_branch_paths_remote")
    File.write!(Path.join(remote, "kept.ex"), "kept\n")
    File.write!(Path.join(remote, "edited.ex"), "before\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "base"])

    repo = create_temp_git_repo(prefix: "rail_branch_paths")
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "shipped.ex"), "committed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "committed change"])
    File.write!(Path.join(repo, "edited.ex"), "after\n")
    File.write!(Path.join(repo, "wip.ex"), "untracked\n")

    %{task: %Task{project_id: project.id, worktree_path: repo}}
  end

  test "gives back the paths the branch changed since it forked, committed, edited or untracked", %{task: task} do
    paths = ["shipped.ex", "edited.ex", "wip.ex", "kept.ex", "lib/made_up.ex"]

    assert Git.list_branch_paths(task, paths) == MapSet.new(["shipped.ex", "edited.ex", "wip.ex"])
    assert Git.list_branch_paths(task, ["kept.ex"]) == MapSet.new()
  end

  test "says nil where there is no worktree to ask or git cannot read it, and asks nothing of no paths", %{task: task} do
    assert Git.list_branch_paths(%{task | worktree_path: nil}, ["shipped.ex"]) == nil
    assert Git.list_branch_paths(%{task | worktree_path: Path.join(task.worktree_path, "gone")}, ["shipped.ex"]) == nil
    plain = Path.join(System.tmp_dir!(), "rail_branch_paths_plain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf(plain) end)

    assert Git.list_branch_paths(%{task | worktree_path: plain}, ["shipped.ex"]) == nil
    assert Git.list_branch_paths(task, []) == MapSet.new()
  end
end
