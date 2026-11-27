defmodule Rail.Git.Actions.LoadBranchHistoryTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    create_task_checkout(task: [worktree_name: "feature"])
  end

  test "the branch's own commits along the first parent, newest first, each labeled by the rounds and counted", %{
    project: project,
    task: task,
    checkout: checkout,
    remote: remote
  } do
    File.write!(Path.join(checkout, "a.ex"), "engineer\nfirst\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "Send comments as one round"])
    round_1 = checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(remote, "a.ex"), "main\n")
    File.write!(Path.join(remote, "main.ex"), "landed\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Landed on main"])
    main = remote |> git!(["rev-parse", "--short", "HEAD"]) |> String.trim()
    :ok = Git.fetch_default_branch(project, task)
    # It stops on a conflict in a.ex, which the next lines resolve.
    {_conflicted, 1} = Rail.Tools.run("git", ["merge", "--no-edit", "origin/main"], cd: checkout, stderr_to_stdout: true)
    File.write!(Path.join(checkout, "a.ex"), "engineer\nfirst\n")
    git!(checkout, ["add", "a.ex"])
    git!(checkout, ["commit", "--no-edit", "-m", "Merge origin/main"])

    File.write!(Path.join(checkout, "a.ex"), "engineer\nfollowed\n")
    git!(checkout, ["commit", "-am", "Follow main's rename through"])
    round_2 = checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()

    File.write!(Path.join(checkout, "a.ex"), "fixed\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "Fix 2 findings from round 2"])
    head = checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()
    short = checkout |> git!(["rev-parse", "--short", "HEAD"]) |> String.trim()

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
               %{subject: "Send comments as one round", label: "Implement", conflicts: 0, files: 1, additions: 2}
             ]
           } = Git.load_branch_history(task, [round_1, round_2])
  end

  test "before any round read the branch, its commits are the engineer's, and a clean merge met no conflicts", %{
    project: project,
    task: task,
    checkout: checkout,
    remote: remote
  } do
    git!(checkout, ["commit", "--allow-empty", "-m", "The engineer's work"])
    File.write!(Path.join(remote, "main.ex"), "landed\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "Landed on main"])
    :ok = Git.fetch_default_branch(project, task)
    git!(checkout, ["merge", "--no-edit", "origin/main"])

    assert %{commits: [%{label: "Merge main", conflicts: 0}, %{label: "Implement", conflicts: 0}]} =
             Git.load_branch_history(task)
  end

  # Merging what someone pushed to the branch itself brings in none of main, so it is not labeled as main.
  test "a merge of the branch's own remote is labeled by that branch, with its own subject", %{
    task: task,
    checkout: checkout,
    remote: remote
  } do
    git!(checkout, ["commit", "--allow-empty", "-m", "The engineer's work"])
    git!(checkout, ["push", "--quiet", "origin", "feature"])
    git!(remote, ["checkout", "--quiet", "feature"])
    git!(remote, ["commit", "--allow-empty", "-m", "Add Sam's review notes"])
    theirs = remote |> git!(["rev-parse", "--short", "HEAD"]) |> String.trim()
    git!(checkout, ["commit", "--allow-empty", "-m", "More of the engineer's work"])
    git!(checkout, ["fetch", "--quiet", "origin", "feature"])
    git!(checkout, ["merge", "--no-edit", "-m", "Merge remote-tracking branch 'origin/feature'", "origin/feature"])

    assert %{
             commits: [
               %{
                 label: "Merge origin/feature",
                 subject: "Merge remote-tracking branch 'origin/feature'",
                 merge?: true,
                 main?: false,
                 merged: ^theirs
               },
               %{label: "Implement", main?: false},
               %{label: "Implement"}
             ]
           } = Git.load_branch_history(task)
  end

  # A rebase replaces the commits a round read, so what is on the branch now came after it.
  test "a round whose commit a rebase replaced read nothing still on the branch", %{task: task, checkout: checkout} do
    git!(checkout, ["commit", "--allow-empty", "-m", "The engineer's work"])
    read = checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()
    git!(checkout, ["commit", "--amend", "--allow-empty", "-m", "The engineer's work, rebased"])

    assert %{commits: [%{label: "Fix round 1"}]} = Git.load_branch_history(task, [read])
    assert %{commits: [%{label: "Fix round 1"}]} = Git.load_branch_history(task, ["0000000"])
  end

  # A binary file has no lines to count, and a message holding the field mark cannot be read back apart.
  test "a binary file counts no lines, and a commit whose message Rail cannot read apart is left out", %{
    task: task,
    checkout: checkout
  } do
    File.write!(Path.join(checkout, "logo.png"), <<137, 80, 78, 71, 0, 1, 2>>)
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "Add the logo"])
    File.write!(Path.join(checkout, "a.ex"), "a\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "Split \x1f here"])

    assert %{files: 2, additions: 1, commits: [%{subject: "Add the logo", files: 1, additions: 0, deletions: 0}]} =
             Git.load_branch_history(task)
  end

  test "a branch git cannot read has no history", %{task: task} do
    File.rm_rf!(Task.repo_path(task))

    assert %{commits: [], head: nil, files: 0} = Git.load_branch_history(task)
  end
end
