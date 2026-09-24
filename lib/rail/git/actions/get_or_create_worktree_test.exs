defmodule Rail.Git.Actions.GetOrCreateWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project

  setup do
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    remote = create_temp_git_repo(prefix: "rail_worktree_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])

    %{
      remote: remote,
      repo: repo,
      project: %Project{clone_path: repo, default_branch: "main", github_installation_id: 47_061}
    }
  end

  test "returns immediately if worktree_path already exists", %{repo: repo, project: project} do
    wt_path = Path.join(repo, ".worktrees/existing")
    File.mkdir_p!(wt_path)

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-existing"})
  end

  test "creates a new branch from origin's default branch, not the clone's stale local one", %{
    remote: remote,
    repo: repo,
    project: project
  } do
    File.write!(Path.join(remote, "upstream.txt"), "merged since the clone\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream commit"])
    wt_path = Path.join(repo, ".worktrees/feature-1")

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-1"})

    assert File.exists?(Path.join(wt_path, "upstream.txt"))
    assert git!(wt_path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "main"])
  end

  test "leaves the new branch without an upstream, so it reads as never pushed", %{repo: repo, project: project} do
    wt_path = Path.join(repo, ".worktrees/feature-untracked")

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-untracked"})

    assert {_out, 1} = Rail.Tools.run("git", ["config", "branch.feature-untracked.merge"], cd: repo)
  end

  test "checks out existing branch if branch already exists in repo", %{repo: repo, project: project} do
    git!(repo, ["branch", "pre-existing-branch"])
    wt_path = Path.join(repo, ".worktrees/feature-pre")

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "pre-existing-branch"})

    assert File.dir?(wt_path)
  end

  test "errors when origin has no such default branch", %{repo: repo, project: project} do
    wt_path = Path.join(repo, ".worktrees/feature-missing-base")

    assert {:error, reason} =
             Git.get_or_create_worktree(
               %{project | default_branch: "primary"},
               %Task{worktree_path: wt_path, worktree_name: "feature-missing-base"}
             )

    assert reason =~ "couldn't find remote ref primary"
    refute File.dir?(wt_path)
  end

  test "creates new worktree from the project's non-main default branch", %{
    remote: remote,
    repo: repo,
    project: project
  } do
    git!(remote, ["branch", "develop"])
    wt_path = Path.join(repo, ".worktrees/feature-from-dev")

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(
               %{project | default_branch: "develop"},
               %Task{worktree_path: wt_path, worktree_name: "feature-from-dev"}
             )

    assert git!(wt_path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "develop"])
  end

  test "derives the worktree path from the clone path when the task has none", %{repo: repo, project: project} do
    task = %Task{id: "tsk_derived", worktree_name: "feature-derived"}

    expected = Path.join(repo, ".worktrees/feature-derived")
    assert {:ok, ^expected} = Git.get_or_create_worktree(project, task)
    assert File.dir?(expected)
  end

  test "falls back to the task id when the task has no worktree name", %{repo: repo, project: project} do
    task = %Task{id: "tsk_by_id"}

    expected = Path.join(repo, ".worktrees/tsk_by_id")
    assert {:ok, ^expected} = Git.get_or_create_worktree(project, task)
    assert File.dir?(expected)
  end

  test "errors when the clone path is not a repository", %{project: project} do
    fake_repo = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fake_repo)
    on_exit(fn -> File.rm_rf(fake_repo) end)

    wt_path = Path.join(fake_repo, ".worktrees/fail")

    assert {:error, reason} =
             Git.get_or_create_worktree(
               %{project | clone_path: fake_repo},
               %Task{worktree_path: wt_path, worktree_name: "fail-branch"}
             )

    assert reason =~ "not a git repository"
  end
end
