defmodule Rail.Git.Actions.GitRepoTest do
  use ExUnit.Case, async: true

  alias Rail.Git.Actions.GitRepo

  test "a checkout root is a git repo" do
    assert GitRepo.git_repo?(File.cwd!())
  end

  test "a directory with no .git is not" do
    refute GitRepo.git_repo?(Path.join(File.cwd!(), "lib"))
  end
end
