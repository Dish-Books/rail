defmodule Rail.Git.Actions.CheckoutDetachedWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Pipeline.Schemas.Task, as: PipelineTask
  alias Rail.Projects.Schemas.Project

  setup do
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    remote = create_temp_git_repo(prefix: "rail_detached_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])

    %{remote: remote, repo: repo, project: %Project{clone_path: repo, default_branch: "main", github_installation_id: 1}}
  end

  test "checks out origin's default branch detached, fetched first", %{remote: remote, repo: repo, project: project} do
    File.write!(Path.join(remote, "upstream.txt"), "merged since the clone\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream commit"])
    path = Path.join(repo, ".worktrees/triage-1")

    assert {:ok, ^path} = Git.checkout_detached_worktree(project, path)

    assert git!(path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "main"])
    assert {_branch, 1} = Rail.Tools.run("git", ["symbolic-ref", "-q", "HEAD"], cd: path)
  end

  # A pass's sandbox mounts only the checkout, so its history has to be its own.
  test "the checkout is a clone of its own, whose history reads with the project's clone gone", %{
    remote: remote,
    repo: repo,
    project: project
  } do
    path = Path.join(repo, ".worktrees/support-1")
    assert {:ok, ^path} = Git.checkout_detached_worktree(project, path)

    assert File.dir?(Path.join(path, ".git"))
    refute git!(repo, ["worktree", "list"]) =~ path

    moved = Path.join(System.tmp_dir!(), "rail_detached_moved_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(moved) end)
    File.rename!(path, moved)
    File.rm_rf!(repo)

    assert git!(moved, ["log", "--format=%s"]) =~ "initial commit"
    assert git!(moved, ["show", "--stat", "HEAD"]) =~ "tracked.txt"
    assert git!(moved, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "main"])
  end

  test "replaces a stale worktree left at the path", %{remote: remote, repo: repo, project: project} do
    path = Path.join(repo, ".worktrees/triage-2")
    assert {:ok, ^path} = Git.checkout_detached_worktree(project, path)
    File.write!(Path.join(path, "leftover.txt"), "from the last pass\n")

    File.write!(Path.join(remote, "newer.txt"), "newer\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "newer"])

    assert {:ok, ^path} = Git.checkout_detached_worktree(project, path)
    refute File.exists?(Path.join(path, "leftover.txt"))
    assert File.exists?(Path.join(path, "newer.txt"))
  end

  test "says what git said when origin has no such branch", %{repo: repo, project: project} do
    assert {:error, reason} =
             Git.checkout_detached_worktree(%{project | default_branch: "primary"}, Path.join(repo, ".worktrees/t3"))

    assert reason =~ "couldn't find remote ref primary"
  end

  test "says what git said when the checkout cannot be made", %{repo: repo, project: project} do
    blocker = Path.join(repo, ".worktrees/blocked")
    File.mkdir_p!(Path.dirname(blocker))
    File.write!(blocker, "a file where the worktree should go")

    assert {:error, reason} = Git.checkout_detached_worktree(project, blocker)
    assert reason =~ "Failed to create the checkout at #{blocker}"
  end

  test "pipeline clones and triage worktrees made and removed at once from one clone all succeed", %{
    repo: repo,
    project: project
  } do
    results =
      1..16
      |> Task.async_stream(
        fn i ->
          path = Path.join(repo, ".worktrees/at-once-#{i}")

          for round <- 1..4 do
            task = %PipelineTask{worktree_path: path, worktree_name: "at-once-#{i}-#{round}"}

            if rem(i, 2) == 0,
              do: {Git.checkout_detached_worktree(project, path), Git.remove_worktree(repo, path)},
              else: {Git.get_or_create_worktree(project, task), Git.remove_task_checkout(project, task)}
          end
        end,
        max_concurrency: 16,
        timeout: 120_000
      )
      |> Enum.flat_map(fn {:ok, rounds} -> rounds end)

    assert Enum.all?(results, &match?({{:ok, _path}, :ok}, &1)),
           inspect(Enum.reject(results, &match?({{:ok, _path}, :ok}, &1)))
  end
end
