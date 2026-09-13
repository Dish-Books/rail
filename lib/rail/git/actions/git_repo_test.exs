defmodule Rail.Git.Actions.GitRepoTest do
  use ExUnit.Case, async: true

  alias Rail.Git

  test "a checkout root is a git repo" do
    assert Git.git_repo?(File.cwd!())
  end

  test "a directory with no .git is not" do
    refute Git.git_repo?(Path.join(File.cwd!(), "lib"))
  end
end
