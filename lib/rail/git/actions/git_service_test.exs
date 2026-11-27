defmodule Rail.Git.Actions.GitServiceTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout()
  end

  test "runs upload-pack against the task's repository with Rail's hardened git environment", %{task: task, repo: repo} do
    assert {git, ["upload-pack", "--strict", ^repo], env} = Git.git_service(task, "git-upload-pack")

    assert Path.basename(git) == "git"
    assert env["GIT_CONFIG_PARAMETERS"] =~ "'core.hooksPath'='/dev/null'"
    assert env["GIT_ALLOW_PROTOCOL"] == "file:http:https:ssh"
    assert env["PATH"] =~ "/"
  end

  test "runs receive-pack against the task's repository, with no hook", %{task: task} do
    repo = Task.repo_path(task)

    assert {_git, ["receive-pack", ^repo], %{"GIT_CONFIG_PARAMETERS" => parameters}} =
             Git.git_service(task, "git-receive-pack")

    assert parameters =~ "'core.hooksPath'='/dev/null'"
  end

  test "runs nothing else a channel names", %{task: task} do
    assert {:error, :unsupported} = Git.git_service(task, "git-upload-archive")
  end
end
