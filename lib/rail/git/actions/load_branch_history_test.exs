defmodule Rail.Git.Actions.LoadBranchHistoryTest do
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
            "issue" => %{"id" => "lin_lbh_1", "identifier" => "LBH-1", "title" => "Load Branch History"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Load Branch History"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    remote = create_temp_git_repo(prefix: "rail_branch_history_remote")
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])
    git!(repo, ["checkout", "-b", "feature"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, repo: repo, remote: remote}
  end

  test "the branch's own commits along the first parent, newest first, each labeled by the rounds and counted", %{
    task: task,
    repo: repo,
    remote: remote
  } do
    File.write!(Path.join(repo, "a.ex"), "engineer\nfirst\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "Send comments as one round"])
    round_1 = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(remote, "a.ex"), "main\n")
    File.write!(Path.join(remote, "main.ex"), "landed\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Landed on main"])
    main = remote |> git!(["rev-parse", "--short", "HEAD"]) |> String.trim()
    git!(repo, ["fetch", "origin", "main"])
    # It stops on a conflict in a.ex, which the next lines resolve.
    {_conflicted, 1} = Rail.Tools.run("git", ["merge", "--no-edit", "origin/main"], cd: repo, stderr_to_stdout: true)
    File.write!(Path.join(repo, "a.ex"), "engineer\nfirst\n")
    git!(repo, ["add", "a.ex"])
    git!(repo, ["commit", "--no-edit", "-m", "Merge origin/main"])

    File.write!(Path.join(repo, "a.ex"), "engineer\nfollowed\n")
    git!(repo, ["commit", "-am", "Follow main's rename through"])
    round_2 = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(repo, "a.ex"), "fixed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "Fix 2 findings from round 2"])
    head = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
    short = repo |> git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

    assert %{
             base: "main",
             head: ^short,
             files: 1,
             additions: 1,
             deletions: 1,
             commits: [
               %{
                 sha: ^head,
                 short_sha: ^short,
                 subject: "Fix 2 findings from round 2",
                 label: "Fix round 2",
                 at: %DateTime{},
                 merge?: false,
                 files: 1,
                 additions: 1,
                 deletions: 2
               },
               %{subject: "Follow main's rename through", label: "Fix round 1", files: 1, additions: 1, deletions: 1},
               %{label: "Merge main", merge?: true, merged: ^main, conflicts: 1, files: 1, additions: 1, deletions: 0},
               %{subject: "Send comments as one round", label: "Engineer", conflicts: 0, files: 1, additions: 2}
             ]
           } = Git.load_branch_history(task, [round_1, round_2])
  end

  test "before any round read the branch, its commits are the engineer's, and a clean merge met no conflicts", %{
    task: task,
    repo: repo,
    remote: remote
  } do
    git!(repo, ["commit", "--allow-empty", "-m", "The engineer's work"])
    File.write!(Path.join(remote, "main.ex"), "landed\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Landed on main"])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["merge", "--no-edit", "origin/main"])

    assert %{commits: [%{label: "Merge main", conflicts: 0}, %{label: "Engineer", conflicts: 0}]} =
             Git.load_branch_history(task)
  end

  # A rebase replaces the commits a round read, so what is on the branch now came after it.
  test "a round whose commit a rebase replaced read nothing still on the branch", %{task: task, repo: repo} do
    git!(repo, ["commit", "--allow-empty", "-m", "The engineer's work"])
    read = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(repo, ["commit", "--amend", "--allow-empty", "-m", "The engineer's work, rebased"])

    assert %{commits: [%{label: "Fix round 1"}]} = Git.load_branch_history(task, [read])
    assert %{commits: [%{label: "Fix round 1"}]} = Git.load_branch_history(task, ["0000000"])
  end

  # A binary file has no lines to count, and a message holding the field mark cannot be read back apart.
  test "a binary file counts no lines, and a commit whose message Rail cannot read apart is left out", %{
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "logo.png"), <<137, 80, 78, 71, 0, 1, 2>>)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "Add the logo"])
    File.write!(Path.join(repo, "a.ex"), "a\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "Split \x1f here"])

    assert %{files: 2, additions: 1, commits: [%{subject: "Add the logo", files: 1, additions: 0, deletions: 0}]} =
             Git.load_branch_history(task)
  end

  test "a branch git cannot read has no history", %{task: task} do
    assert %{commits: [], head: nil, files: 0} = Git.load_branch_history(%{task | worktree_path: System.tmp_dir!()})
  end
end
