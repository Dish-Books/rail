defmodule Rail.Git.Actions.ReadDefaultBranchFileTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Projects.Schemas.Project

  setup do
    remote = create_temp_git_repo(prefix: "rail_read_remote")
    File.mkdir_p!(Path.join(remote, ".rail/prompts"))
    File.write!(Path.join(remote, ".rail/prompts/engineer.md"), "Merged prompt.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add prompt"])

    clone = create_temp_git_repo(prefix: "rail_read_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])

    %{project: %Project{default_branch: "main", clone_path: clone}, remote: remote, clone: clone}
  end

  test "returns the file as committed on the fetched default branch", %{project: project} do
    assert {:ok, "Merged prompt.\n"} = Git.read_default_branch_file(project, ".rail/prompts/engineer.md")
  end

  test "reads the fetched ref, not the clone's working tree", %{project: project, clone: clone} do
    File.mkdir_p!(Path.join(clone, ".rail/prompts"))
    File.write!(Path.join(clone, ".rail/prompts/engineer.md"), "Working tree.\n")

    assert {:ok, "Merged prompt.\n"} = Git.read_default_branch_file(project, ".rail/prompts/engineer.md")
  end

  test "fails for a path the default branch does not have, saying so", %{project: project} do
    assert {:error, message} = Git.read_default_branch_file(project, "missing.md")
    assert message =~ "does not exist"
  end

  test "fails for a file committed only on another branch", %{project: project, remote: remote, clone: clone} do
    git!(remote, ["checkout", "-b", "task-branch"])
    File.write!(Path.join(remote, ".rail/prompts/review.md"), "Unmerged.\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "unmerged prompt"])
    git!(clone, ["fetch", "origin", "task-branch"])

    assert {:error, _output} = Git.read_default_branch_file(project, ".rail/prompts/review.md")
  end

  test "fails for a clone that has never fetched the default branch" do
    clone = create_temp_git_repo(prefix: "rail_read_unfetched")
    project = %Project{default_branch: "main", clone_path: clone}

    assert {:error, _output} = Git.read_default_branch_file(project, "tracked.txt")
  end

  test "fails for a clone_path that does not exist" do
    project = %Project{default_branch: "main", clone_path: "/tmp/rail_read_missing_#{System.unique_integer([:positive])}"}

    assert {:error, _output} = Git.read_default_branch_file(project, ".rail/prompts/engineer.md")
  end
end
