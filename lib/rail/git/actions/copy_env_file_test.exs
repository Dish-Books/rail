defmodule Rail.Git.Actions.CopyEnvFileTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Projects.Schemas.Project

  setup do
    clone = create_temp_git_repo(prefix: "rail_copy_env_clone")
    worktree = Path.join(clone, ".worktrees/copy-env")
    git!(clone, ["worktree", "add", "-b", "copy-env", worktree])

    %{project: %Project{clone_path: clone}, worktree: worktree}
  end

  test "a worktree with no .env of its own gets the clone's lines between Rail's markers", %{
    project: project,
    worktree: worktree
  } do
    File.write!(Path.join(project.clone_path, ".env"), "# A comment\n\nFOO=bar\n")

    assert :ok = Git.copy_env_file(project, worktree)

    assert File.read!(Path.join(worktree, ".env")) == """
           # >>> Rail: the project's .env, rewritten on every save >>>
           # A comment
           FOO=bar
           # <<< Rail: the project's .env <<<
           """

    assert git!(worktree, ["status", "--porcelain"]) == ""
  end

  test "a clone with no .env gives the worktree none", %{project: project, worktree: worktree} do
    assert :ok = Git.copy_env_file(project, worktree)
    refute File.exists?(Path.join(worktree, ".env"))
  end
end
