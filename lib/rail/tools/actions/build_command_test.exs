defmodule Rail.Tools.Actions.BuildCommandTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  test "gives what run/3 would run for git: the resolved executable, its flags and its hardened environment" do
    assert {git, ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "HEAD"], env} =
             Tools.build_command("git", ["diff", "HEAD"], env: %{"GIT_DIR" => "/srv/rail/repo.git"})

    assert String.ends_with?(git, "/git")
    assert env["GIT_DIR"] == "/srv/rail/repo.git"
    assert env["GIT_CONFIG_PARAMETERS"] =~ "'core.hooksPath'='/dev/null'"
    assert env["GIT_OPTIONAL_LOCKS"] == "0"
    assert env["PATH"] =~ "/"
  end

  test "gives any other tool its arguments as they are, and an environment of its own" do
    assert {_ls, ["-la"], env} = Tools.build_command("ls", ["-la"])
    refute Map.has_key?(env, "GIT_CONFIG_PARAMETERS")
  end
end
