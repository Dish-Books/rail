defmodule Rail.Git.Actions.BranchChangedTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_bch_1", "identifier" => "BCH-1", "title" => "Branch Changed"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Branch Changed"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    remote = create_temp_git_repo(prefix: "rail_branch_changed_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])
    git!(repo, ["checkout", "-b", "feature"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, repo: repo}
  end

  test "a branch that has done nothing has not changed", %{task: task} do
    refute Git.branch_changed?(task)
  end

  test "a commit on the branch is a change", %{task: task, repo: repo} do
    File.write!(Path.join(repo, "shipped.ex"), "committed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "committed change"])

    assert Git.branch_changed?(task)
  end

  test "an edit nobody has committed is a change", %{task: task, repo: repo} do
    File.write!(Path.join(repo, "tracked.txt"), "edited\n")

    assert Git.branch_changed?(task)
  end

  test "a file git has never seen is a change", %{task: task, repo: repo} do
    File.write!(Path.join(repo, "brand_new.ex"), "new\n")

    assert Git.branch_changed?(task)
  end

  test "a new file under .rail is a change, like any other", %{task: task, repo: repo} do
    File.mkdir_p!(Path.join(repo, ".rail"))
    File.write!(Path.join(repo, ".rail/notes.md"), "notes\n")

    assert Git.branch_changed?(task)
  end

  # The diff would draw nothing for it, so neither does this.
  test "an untracked file that cannot be read is not a change", %{task: task, repo: repo} do
    File.ln_s!("nowhere", Path.join(repo, "dangling.ex"))

    refute Git.branch_changed?(task)
  end

  test "a worktree that is not a repository has not changed", %{task: task} do
    loose = Path.join(System.tmp_dir!(), "not_a_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(loose)
    on_exit(fn -> File.rm_rf(loose) end)

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: loose})

    refute Git.branch_changed?(task)
  end

  test "a task whose worktree is gone has not changed", %{task: task} do
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: "/tmp/gone_#{System.unique_integer([:positive])}"})

    refute Git.branch_changed?(task)
  end
end
