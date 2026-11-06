defmodule Rail.Git.Actions.ListDefaultBranchPathsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Projects.Schemas.Project

  setup do
    remote = create_temp_git_repo(prefix: "rail_paths_remote")
    File.mkdir_p!(Path.join(remote, "lib/rail/pipeline"))
    File.write!(Path.join(remote, "lib/rail/pipeline/enter_stage.ex"), "merged\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add enter_stage"])

    clone = create_temp_git_repo(prefix: "rail_paths_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])

    %{project: %Project{default_branch: "main", clone_path: clone}, remote: remote, clone: clone}
  end

  test "gives back only the paths on the fetched default branch", %{project: project, remote: remote, clone: clone} do
    git!(remote, ["checkout", "-b", "task-branch"])
    File.write!(Path.join(remote, "lib/rail/pipeline/notify_waiting.ex"), "unmerged\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "unmerged"])
    git!(clone, ["fetch", "origin", "task-branch"])
    File.write!(Path.join(clone, "lib_only_in_working_tree.ex"), "local\n")

    paths = [
      "lib/rail/pipeline/enter_stage.ex",
      "lib/rail/pipeline/notify_waiting.ex",
      "lib/rail/made_up.ex",
      "lib_only_in_working_tree.ex"
    ]

    assert Git.list_default_branch_paths(project, paths) == MapSet.new(["lib/rail/pipeline/enter_stage.ex"])
  end

  test "leaves out a path that is a directory on the default branch", %{project: project} do
    assert Git.list_default_branch_paths(project, ["lib/rail"]) == MapSet.new()
  end

  test "asks git nothing for no paths", %{project: project} do
    reject(&Rail.Tools.run/3)

    assert Git.list_default_branch_paths(project, []) == MapSet.new()
  end

  test "is nil for a clone that has never fetched the default branch" do
    clone = create_temp_git_repo(prefix: "rail_paths_unfetched")

    assert Git.list_default_branch_paths(%Project{default_branch: "main", clone_path: clone}, ["tracked.txt"]) == nil
  end

  test "is nil for a clone_path that does not exist" do
    project = %Project{
      default_branch: "main",
      clone_path: "/tmp/rail_paths_missing_#{System.unique_integer([:positive])}"
    }

    assert Git.list_default_branch_paths(project, ["lib/rail/pipeline/enter_stage.ex"]) == nil
  end
end
