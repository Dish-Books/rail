defmodule Rail.Git.Actions.GetOrCreateWorktreeTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Tools

  setup do
    Req.Test.stub(Client, &Req.Test.json(&1, %{"token" => "ghs_token"}))
    remote = create_temp_git_repo(prefix: "rail_worktree_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    tasks = Path.join([Rail.tasks_root(), "prj_get_or_create_#{System.unique_integer([:positive])}"])
    on_exit(fn -> File.rm_rf(tasks) end)

    %{
      remote: remote,
      repo: repo,
      tasks: tasks,
      project: %Project{clone_path: repo, default_branch: "main", github_installation_id: 47_061}
    }
  end

  test "returns immediately if worktree_path already exists", %{repo: repo, project: project} do
    wt_path = Path.join(repo, ".worktrees/existing")
    File.mkdir_p!(wt_path)

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-existing"})
  end

  test "makes a clone of its own, pushing to the project's origin, that the project's clone knows nothing of", %{
    remote: remote,
    repo: repo,
    tasks: tasks,
    project: project
  } do
    File.write!(Path.join(repo, ".git/hooks/pre-push"), "#!/bin/sh\nexit 0\n")
    wt_path = Path.join([tasks, "feature-own", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-own"})

    assert git!(wt_path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]) =~ wt_path <> "/.git"
    assert git!(wt_path, ["remote", "get-url", "origin"]) == remote <> "\n"
    assert File.read!(Path.join(wt_path, ".git/hooks/pre-push")) == "#!/bin/sh\nexit 0\n"
    assert git!(wt_path, ["branch", "--show-current"]) == "feature-own\n"
    refute git!(repo, ["branch", "--list"]) =~ "feature-own"
    refute git!(repo, ["worktree", "list"]) =~ "feature-own"
    refute File.exists?(wt_path <> ".new")
  end

  test "starts a new branch at origin's latest default branch, not the clone's stale local one, tracking nothing", %{
    remote: remote,
    tasks: tasks,
    project: project
  } do
    File.write!(Path.join(remote, "upstream.txt"), "merged since the clone\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "upstream commit"])
    wt_path = Path.join([tasks, "feature-1", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-1"})

    assert File.exists?(Path.join(wt_path, "upstream.txt"))
    assert git!(wt_path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "main"])
    assert git!(wt_path, ["rev-parse", "origin/main"]) == git!(remote, ["rev-parse", "main"])
    assert {_no_upstream, 1} = Tools.run("git", ["config", "branch.feature-1.merge"], cd: wt_path)
    refute Git.branch_unpushed?(wt_path)
  end

  test "lists only the default branch among its remote branches, not the project clone's other branches", %{
    repo: repo,
    tasks: tasks,
    project: project
  } do
    git!(repo, ["branch", "another-task"])
    wt_path = Path.join([tasks, "feature-single", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-single"})

    assert wt_path |> git!(["branch", "--remotes", "--format=%(refname:short)"]) |> String.split() |> Enum.sort() ==
             ["origin", "origin/main"]
  end

  test "a branch pushed from it reads as pushed, and survives the project's clone being moved aside", %{
    remote: remote,
    repo: repo,
    tasks: tasks,
    project: project
  } do
    wt_path = Path.join([tasks, "feature-pushed", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-pushed"})

    aside = repo <> "_aside"
    File.rename!(repo, aside)
    on_exit(fn -> File.rm_rf(aside) end)

    git!(wt_path, ["config", "user.name", "Rail Test"])
    git!(wt_path, ["config", "user.email", "test@rail.local"])
    File.write!(Path.join(wt_path, "work.txt"), "work\n")
    git!(wt_path, ["add", "."])
    git!(wt_path, ["commit", "-m", "Work after the clone moved"])
    assert git!(wt_path, ["log", "--format=%s"]) == "Work after the clone moved\ninitial commit\n"
    assert Git.branch_unpushed?(wt_path)

    git!(wt_path, ["push", "--set-upstream", "origin", "feature-pushed"])

    assert git!(remote, ["rev-parse", "feature-pushed"]) == git!(wt_path, ["rev-parse", "HEAD"])
    refute Git.branch_unpushed?(wt_path)
  end

  test "a task with a pull request starts on its branch as the remote has it", %{
    remote: remote,
    tasks: tasks,
    project: project
  } do
    git!(remote, ["checkout", "--quiet", "-b", "outside/work"])
    File.write!(Path.join(remote, "work.ex"), "work\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Work done outside Rail"])
    git!(remote, ["checkout", "--quiet", "main"])
    wt_path = Path.join([tasks, "outside/work", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{
               worktree_path: wt_path,
               worktree_name: "outside/work",
               pr_number: 7
             })

    assert git!(wt_path, ["branch", "--show-current"]) == "outside/work\n"
    assert git!(wt_path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "outside/work"])
    assert {_no_upstream, 1} = Tools.run("git", ["config", "branch.outside/work.merge"], cd: wt_path)
  end

  test "a pull request whose branch the remote does not have leaves nothing behind", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "gone", "repo"])

    assert {:error, "Failed to create the task's clone at " <> reason} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "gone", pr_number: 8})

    assert reason =~ "couldn't find remote ref"
    refute File.exists?(wt_path)
    refute File.exists?(wt_path <> ".new")
  end

  test "errors when origin has no such default branch", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-missing-base", "repo"])

    assert {:error, reason} =
             Git.get_or_create_worktree(
               %{project | default_branch: "primary"},
               %Task{worktree_path: wt_path, worktree_name: "feature-missing-base"}
             )

    assert reason =~ "couldn't find remote ref primary"
    refute File.dir?(wt_path)
  end

  test "passes on GitHub refusing a token as it came", %{tasks: tasks, project: project} do
    Req.Test.stub(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))
    wt_path = Path.join([tasks, "feature-no-token", "repo"])

    assert {:error, {:github_api_error, 404, _body}} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-no-token"})
  end

  test "says what git said when the branch cannot be created, and leaves nothing behind", %{
    tasks: tasks,
    project: project
  } do
    wt_path = Path.join([tasks, "bad-name", "repo"])

    assert {:error, reason} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "bad..name"})

    assert reason =~ "Failed to create the task's clone at #{wt_path}"
    assert reason =~ "not a valid branch name"
    refute File.exists?(wt_path <> ".new")
  end

  test "starts from the project's non-main default branch, one the project's clone has never had", %{
    remote: remote,
    tasks: tasks,
    project: project
  } do
    git!(remote, ["branch", "develop"])
    wt_path = Path.join([tasks, "feature-from-dev", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(
               %{project | default_branch: "develop"},
               %Task{worktree_path: wt_path, worktree_name: "feature-from-dev"}
             )

    assert git!(wt_path, ["rev-parse", "HEAD"]) == git!(remote, ["rev-parse", "develop"])
  end

  test "derives the path from the clone path when the task has none", %{repo: repo, project: project} do
    task = %Task{id: "tsk_derived", worktree_name: "feature-derived"}

    expected = Path.join(repo, ".worktrees/feature-derived")
    assert {:ok, ^expected} = Git.get_or_create_worktree(project, task)
    assert File.dir?(Path.join(expected, ".git"))
  end

  test "falls back to the task id when the task has no worktree name", %{repo: repo, project: project} do
    task = %Task{id: "tsk_by_id"}

    expected = Path.join(repo, ".worktrees/tsk_by_id")
    assert {:ok, ^expected} = Git.get_or_create_worktree(project, task)
    assert git!(expected, ["branch", "--show-current"]) == "tsk_by_id\n"
  end

  test "errors when the clone path is not a repository", %{tasks: tasks, project: project} do
    fake_repo = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(fake_repo)
    on_exit(fn -> File.rm_rf(fake_repo) end)

    wt_path = Path.join([tasks, "fail", "repo"])

    assert {:error, reason} =
             Git.get_or_create_worktree(
               %{project | clone_path: fake_repo},
               %Task{worktree_path: wt_path, worktree_name: "fail-branch"}
             )

    assert reason =~ "not a git repository"
  end

  test "says what git said when the project's clone cannot be cloned", %{repo: repo, tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-no-clone", "repo"])

    stub(Tools, :run, fn
      "git", ["clone" | _rest], _opts -> {"fatal: out of space\n", 128}
      command, args, opts -> call_original(Tools, :run, [command, args, opts])
    end)

    reason = "Failed to create the task's clone at #{wt_path}: fatal: out of space"

    assert {:error, ^reason} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-no-clone"})

    refute git!(repo, ["branch", "--list"]) =~ "feature-no-clone"
  end

  test "a new clone of a project with no setup script has the clone's .env at once, never as a change", %{
    repo: repo,
    tasks: tasks,
    project: project
  } do
    File.write!(Path.join(repo, ".env"), "FOO=bar\n")
    wt_path = Path.join([tasks, "feature-env", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-env"})

    assert File.read!(Path.join(wt_path, ".env")) =~ "\nFOO=bar\n"
    assert git!(wt_path, ["status", "--porcelain"]) == ""
  end

  test "a new clone whose .env cannot be written is not left, so the next attempt makes it again", %{
    repo: repo,
    tasks: tasks,
    project: project
  } do
    File.mkdir_p!(Path.join(repo, ".env"))
    wt_path = Path.join([tasks, "feature-env-refused", "repo"])

    assert {:error, "Failed to create the task's clone at " <> reason} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-env-refused"})

    assert reason =~ Path.join(repo, ".env")
    refute File.exists?(wt_path)
    refute File.exists?(wt_path <> ".new")
  end

  test "a new clone that cannot be moved into place is not left half made", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-stuck", "repo"])
    expect(File, :rename, fn _from, ^wt_path -> {:error, :eacces} end)

    message = "Failed to create the task's clone at #{wt_path}: #{wt_path}: permission denied"

    assert {:error, ^message} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-stuck"})

    refute File.exists?(wt_path <> ".new")
  end

  test "two starts at once make one whole clone, which both are given", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-twice", "repo"])
    task = %Task{worktree_path: wt_path, worktree_name: "feature-twice"}

    starts = for _start <- 1..4, do: Elixir.Task.async(fn -> Git.get_or_create_worktree(project, task) end)
    results = Elixir.Task.await_many(starts, 60_000)

    assert results == List.duplicate({:ok, wt_path}, 4)
    assert git!(wt_path, ["branch", "--show-current"]) == "feature-twice\n"
    assert git!(wt_path, ["status", "--porcelain"]) == ""
    refute File.exists?(wt_path <> ".new")
  end

  test "a clone left half made by an earlier attempt is made again rather than reused", %{
    tasks: tasks,
    project: project
  } do
    wt_path = Path.join([tasks, "feature-retried", "repo"])
    File.mkdir_p!(Path.join(wt_path <> ".new", "leftover"))

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-retried"})

    refute File.exists?(Path.join(wt_path, "leftover"))
    refute File.exists?(wt_path <> ".new")
  end

  test "a new clone of a project with a setup script waits for it to succeed for its .env", %{
    repo: repo,
    tasks: tasks,
    project: project
  } do
    File.write!(Path.join(repo, ".env"), "FOO=bar\n")
    wt_path = Path.join([tasks, "feature-scripted", "repo"])

    assert {:ok, ^wt_path} =
             Git.get_or_create_worktree(
               %{project | worktree_setup_script: "scripts/setup.sh"},
               %Task{worktree_path: wt_path, worktree_name: "feature-scripted"}
             )

    refute File.exists?(Path.join(wt_path, ".env"))
  end
end
