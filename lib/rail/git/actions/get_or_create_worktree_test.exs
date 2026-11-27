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

  test "a task whose repository and checkout are there is given them as they are", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-existing", "repo"])
    task = %Task{worktree_path: wt_path, worktree_name: "feature-existing"}
    assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
    File.write!(Path.join(wt_path, "work.ex"), "uncommitted\n")
    reject(Git, :fetch_default_branch, 2)

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
    assert File.read!(Path.join(wt_path, "work.ex")) == "uncommitted\n"
  end

  test "makes the task a bare repository of Rail's, borrowing the project clone's objects and holding its branch", %{
    remote: remote,
    repo: repo,
    tasks: tasks,
    project: project
  } do
    wt_path = Path.join([tasks, "feature-repo", "repo"])
    task = %Task{worktree_path: wt_path, worktree_name: "feature-repo"}

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)

    task_repo = Task.repo_path(task)
    assert git!(task_repo, ["rev-parse", "--is-bare-repository"]) == "true\n"
    assert git!(task_repo, ["symbolic-ref", "HEAD"]) == "refs/heads/feature-repo\n"
    assert git!(task_repo, ["rev-parse", "refs/heads/feature-repo"]) == git!(remote, ["rev-parse", "main"])
    assert git!(task_repo, ["config", "remote.origin.url"]) == remote <> "\n"
    assert git!(task_repo, ["config", "core.logallrefupdates"]) == "true\n"
    assert File.read!(Path.join(task_repo, "objects/info/alternates")) =~ Path.join(repo, ".git/objects")

    assert task_repo |> File.ls!() |> Enum.reject(&(&1 in ["HEAD", "config", "objects", "refs", "logs", "packed-refs"])) ==
             []

    refute File.exists?(task_repo <> ".new")
  end

  test "makes a clone of its own, pushing to the project's origin, with none of the clone's hooks, that the project's clone knows nothing of",
       %{
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
    # Rail runs none of a project's hooks, so the clone's are left behind.
    refute File.exists?(Path.join(wt_path, ".git/hooks/pre-push"))
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
    refute Git.branch_unpushed?(%Task{worktree_path: wt_path, worktree_name: "feature-1"})
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

    # origin/HEAD is only a pointer, and whether a clone gets one depends on git's version, so it is left out.
    assert wt_path
           |> git!(["for-each-ref", "--format=%(refname)", "refs/remotes"])
           |> String.split()
           |> Enum.reject(&(&1 == "refs/remotes/origin/HEAD")) == ["refs/remotes/origin/main"]
  end

  test "a commit made in the checkout reads as the branch's own, not yet pushed", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-pushed", "repo"])
    task = %Task{worktree_path: wt_path, worktree_name: "feature-pushed"}
    assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)

    File.write!(Path.join(wt_path, "work.txt"), "work\n")
    git!(wt_path, ["add", "."])
    git!(wt_path, ["commit", "-m", "Work in the checkout"])
    assert git!(wt_path, ["log", "--format=%s"]) == "Work in the checkout\ninitial commit\n"

    assert Git.branch_unpushed?(task)
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
    refute File.exists?(wt_path <> ".git")
    refute File.exists?(wt_path <> ".git.new")
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

  test "falls back to the task id when the task has no worktree name", %{tasks: tasks, project: project} do
    expected = Path.join([tasks, "tsk_by_id", "repo"])
    task = %Task{id: "tsk_by_id", worktree_path: expected}

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

    stub(File, :rename, fn
      _from, ^wt_path -> {:error, :eacces}
      from, to -> call_original(File, :rename, [from, to])
    end)

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

  test "a repository that cannot be moved into place is not left half made", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-stuck-repo", "repo"])
    task_repo = wt_path <> ".git"
    expect(File, :rename, fn _from, ^task_repo -> {:error, :eacces} end)

    message = "Failed to create the task's clone at #{wt_path}: #{task_repo}: permission denied"

    assert {:error, ^message} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-stuck-repo"})

    refute File.exists?(task_repo)
    refute File.exists?(task_repo <> ".new")
  end

  test "says what git said when the task's repository cannot be set up", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-no-config", "repo"])

    stub(Tools, :run, fn
      "git", ["config", "core.logallrefupdates" | _rest], _opts -> {"error: could not lock config file\n", 255}
      command, args, opts -> call_original(Tools, :run, [command, args, opts])
    end)

    reason = "Failed to create the task's clone at #{wt_path}: error: could not lock config file"

    assert {:error, ^reason} =
             Git.get_or_create_worktree(project, %Task{worktree_path: wt_path, worktree_name: "feature-no-config"})

    refute File.exists?(wt_path <> ".git")
  end

  test "a checkout made again over a repository it synced into starts with that work in it, uncommitted", %{
    tasks: tasks,
    project: project
  } do
    wt_path = Path.join([tasks, "feature-again", "repo"])
    task = %Task{worktree_path: wt_path, worktree_name: "feature-again"}
    {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
    git!(wt_path, ["commit", "--allow-empty", "-m", "committed"])
    File.write!(Path.join(wt_path, "tracked.txt"), "edited\n")
    File.write!(Path.join(wt_path, "new.ex"), "new\n")
    File.rm_rf!(Path.join(wt_path, ".env"))
    assert :ok = Git.sync_checkout(task)
    File.rm_rf!(wt_path)

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)

    assert git!(wt_path, ["log", "-1", "--format=%s"]) == "committed\n"
    assert File.read!(Path.join(wt_path, "tracked.txt")) == "edited\n"
    assert git!(wt_path, ["status", "--porcelain"]) == " M tracked.txt\n?? new.ex\n"
  end

  test "a snapshot taken on an earlier head is not put back over the branch", %{tasks: tasks, project: project} do
    wt_path = Path.join([tasks, "feature-stale", "repo"])
    task = %Task{worktree_path: wt_path, worktree_name: "feature-stale"}
    {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
    File.write!(Path.join(wt_path, "tracked.txt"), "edited\n")
    assert :ok = Git.sync_checkout(task)
    git!(wt_path, ["commit", "--allow-empty", "-m", "committed after"])
    git!(wt_path, ["push", "--quiet", "--force", wt_path <> ".git", "HEAD:refs/heads/feature-stale"])
    File.rm_rf!(wt_path)

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
    assert git!(wt_path, ["status", "--porcelain"]) == ""
  end

  test "under the docker runtime makes the repository alone, since the sandbox clones its own checkout", %{
    tasks: tasks,
    project: project
  } do
    stub(Rail, :sandbox_runtime, fn -> :docker end)
    wt_path = Path.join([tasks, "feature-docker", "repo"])
    task = %Task{worktree_path: wt_path, worktree_name: "feature-docker"}

    assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
    assert Task.worktree_present?(task)
    refute File.exists?(wt_path)
  end

  describe "a task whose checkout was made before its repository" do
    test "of its own clone, takes the branch from origin where origin has it, and keeps the checkout as it is", %{
      remote: remote,
      tasks: tasks,
      project: project
    } do
      git!(remote, ["checkout", "--quiet", "-b", "feature-old"])
      git!(remote, ["commit", "--allow-empty", "-m", "pushed before"])
      git!(remote, ["checkout", "--quiet", "main"])
      wt_path = Path.join([tasks, "feature-old", "repo"])
      git!(System.tmp_dir!(), ["clone", "--quiet", "--branch", "feature-old", remote, wt_path])
      git!(wt_path, ["commit", "--allow-empty", "-m", "not pushed"])
      File.write!(Path.join(wt_path, "work.ex"), "uncommitted\n")
      task = %Task{worktree_path: wt_path, worktree_name: "feature-old"}

      assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)

      assert git!(wt_path <> ".git", ["log", "-1", "--format=%s", "refs/heads/feature-old"]) == "pushed before\n"
      assert git!(wt_path, ["log", "-1", "--format=%s"]) == "not pushed\n"
      assert File.read!(Path.join(wt_path, "work.ex")) == "uncommitted\n"
      # Its config is Rail's now, as any checkout's on Rail's disk.
      assert git!(wt_path, ["config", "user.email"]) == "rail[bot]@railai.dev\n"

      # The first sync brings the rest in.
      assert Git.list_changed_paths(task) == ["work.ex"]
      assert git!(wt_path <> ".git", ["log", "-1", "--format=%s", "refs/heads/feature-old"]) == "not pushed\n"
    end

    test "starts the branch from the default branch when origin does not have it", %{
      remote: remote,
      tasks: tasks,
      project: project
    } do
      wt_path = Path.join([tasks, "feature-unpushed", "repo"])
      git!(System.tmp_dir!(), ["clone", "--quiet", remote, wt_path])
      task = %Task{worktree_path: wt_path, worktree_name: "feature-unpushed"}

      assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
      assert git!(wt_path <> ".git", ["rev-parse", "refs/heads/feature-unpushed"]) == git!(remote, ["rev-parse", "main"])
    end

    test "on a worktree of the project's clone, leaves the clone's config alone", %{repo: repo, project: project} do
      wt_path = Path.join(repo, ".worktrees/feature-worktree")
      git!(repo, ["worktree", "add", "--quiet", "-b", "feature-worktree", wt_path])
      task = %Task{worktree_path: wt_path, worktree_name: "feature-worktree"}

      assert {:ok, ^wt_path} = Git.get_or_create_worktree(project, task)
      assert Task.worktree_present?(task)
      refute File.read!(Path.join(repo, ".git/config")) =~ "worktreeConfig"
      refute File.read!(Path.join(repo, ".git/config")) =~ "railai"
    end
  end
end
