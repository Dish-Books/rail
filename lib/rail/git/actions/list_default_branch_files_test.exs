defmodule Rail.Git.Actions.ListDefaultBranchFilesTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Projects.Schemas.Project

  setup do
    remote = create_temp_git_repo(prefix: "rail_list_remote")
    File.mkdir_p!(Path.join(remote, ".rail/workflows/nested"))
    File.write!(Path.join(remote, ".rail/workflows/dependency-updates.yml"), "name: Dependency updates\n")
    File.write!(Path.join(remote, ".rail/workflows/with space.yaml"), "name: Spaced\n")
    File.write!(Path.join(remote, ".rail/workflows/nested/deeper.yml"), "name: Deeper\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "add workflows"])

    clone = create_temp_git_repo(prefix: "rail_list_clone")
    git!(clone, ["remote", "add", "origin", remote])
    git!(clone, ["fetch", "origin", "main"])

    %{project: %Project{default_branch: "main", clone_path: clone}, clone: clone}
  end

  test "lists the files directly under the directory on the fetched default branch", %{project: project} do
    assert {:ok, [".rail/workflows/dependency-updates.yml", ".rail/workflows/with space.yaml"]} =
             Git.list_default_branch_files(project, ".rail/workflows")
  end

  test "leaves out files only in the clone's working tree", %{project: project, clone: clone} do
    File.mkdir_p!(Path.join(clone, ".rail/workflows"))
    File.write!(Path.join(clone, ".rail/workflows/local.yml"), "name: Local\n")

    assert {:ok, [".rail/workflows/dependency-updates.yml", ".rail/workflows/with space.yaml"]} =
             Git.list_default_branch_files(project, ".rail/workflows/")
  end

  test "lists nothing for a directory the default branch does not have", %{project: project} do
    assert {:ok, []} = Git.list_default_branch_files(project, ".rail/missing")
  end

  test "fails for a clone that has never fetched the default branch" do
    clone = create_temp_git_repo(prefix: "rail_list_unfetched")

    assert {:error, message} =
             Git.list_default_branch_files(%Project{default_branch: "main", clone_path: clone}, ".rail/workflows")

    assert message =~ "origin/main"
  end
end
