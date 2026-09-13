defmodule Rail.Git.Actions.DeleteBranchTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Tools

  test "deletes an existing branch" do
    repo = create_temp_git_repo()
    git!(repo, ["branch", "to_delete"])

    assert :ok = Git.delete_branch(repo, "to_delete")

    {out, 0} = Tools.run("git", ["branch", "--list", "to_delete"], cd: repo)
    assert String.trim(out) == ""
  end

  test "returns error when deleting non-existent branch" do
    repo = create_temp_git_repo()
    assert {:error, reason} = Git.delete_branch(repo, "non_existent_branch_xyz")
    assert byte_size(reason) > 0
  end
end
