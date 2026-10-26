defmodule Rail.Git.Actions.ListRoundPathsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    remote = create_temp_git_repo(prefix: "rail_round_paths_remote")
    File.write!(Path.join(remote, "bill.ex"), "one\ntwo\nthree\nfour\nfive\n")
    File.write!(Path.join(remote, "vendor.ex"), "vendor\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "base"])

    repo = create_temp_git_repo(prefix: "rail_round_paths")
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "bill.ex"), "ONE\ntwo\nthree\nfour\nfive\n")
    git!(repo, ["commit", "-am", "round 1"])

    %{
      task: %Task{project_id: project.id, worktree_path: repo},
      remote: remote,
      repo: repo,
      base: repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
    }
  end

  test "a round's own commits name the files it changed", %{task: task, repo: repo, base: base} do
    File.mkdir_p!(Path.join(repo, "test"))
    File.write!(Path.join(repo, "test/bill_test.exs"), "test\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "round 2"])

    assert {:ok, ["test/bill_test.exs"]} = Git.list_round_paths(task, %{base: base, merged: false})
  end

  # The default branch's own work is checked there, so only what it changed in the branch's files counts.
  test "a merge counts only what it changed in the files the branch had touched", %{
    task: task,
    remote: remote,
    repo: repo,
    base: base
  } do
    File.write!(Path.join(remote, "bill.ex"), "one\ntwo\nthree\nfour\nFIVE\n")
    File.write!(Path.join(remote, "vendor.ex"), "vendors\n")
    git!(remote, ["commit", "-am", "the default branch's work"])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["merge", "--quiet", "--no-edit", "origin/main"])
    File.write!(Path.join(repo, "notes.md"), "notes\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "round 2's own"])

    assert {:ok, ["bill.ex", "notes.md"]} = Git.list_round_paths(task, %{base: base, merged: true})
  end

  test "a base git does not know cannot be read", %{task: task} do
    assert {:error, :unreadable} = Git.list_round_paths(task, %{base: String.duplicate("0", 40), merged: false})
    assert {:error, :unreadable} = Git.list_round_paths(task, %{base: String.duplicate("0", 40), merged: true})
  end
end
