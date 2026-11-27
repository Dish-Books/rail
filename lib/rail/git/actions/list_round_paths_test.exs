defmodule Rail.Git.Actions.ListRoundPathsTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    %{remote: remote, checkout: checkout} = context = create_task_checkout()
    File.write!(Path.join(remote, "bill.ex"), "one\ntwo\nthree\nfour\nfive\n")
    File.write!(Path.join(remote, "vendor.ex"), "vendor\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "base"])
    :ok = Git.fetch_default_branch(context.project, context.task)
    git!(checkout, ["merge", "--quiet", "origin/main"])
    File.write!(Path.join(checkout, "bill.ex"), "ONE\ntwo\nthree\nfour\nfive\n")
    git!(checkout, ["commit", "-am", "round 1"])

    Map.put(context, :base, checkout |> git!(["rev-parse", "HEAD"]) |> String.trim())
  end

  test "a round's own commits name the files it changed", %{task: task, checkout: checkout, base: base} do
    File.mkdir_p!(Path.join(checkout, "test"))
    File.write!(Path.join(checkout, "test/bill_test.exs"), "test\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "round 2"])

    assert {:ok, ["test/bill_test.exs"]} = Git.list_round_paths(task, %{base: base, merged: false})
  end

  # The default branch's own work is checked there, so only what it changed in the branch's files counts.
  test "a merge counts only what it changed in the files the branch had touched", %{
    task: task,
    project: project,
    remote: remote,
    checkout: checkout,
    base: base
  } do
    File.write!(Path.join(remote, "bill.ex"), "one\ntwo\nthree\nfour\nFIVE\n")
    File.write!(Path.join(remote, "vendor.ex"), "vendors\n")
    git!(remote, ["commit", "-am", "the default branch's work"])
    :ok = Git.fetch_default_branch(project, task)
    git!(checkout, ["merge", "--quiet", "--no-edit", "origin/main"])
    File.write!(Path.join(checkout, "notes.md"), "notes\n")
    git!(checkout, ["add", "."])
    git!(checkout, ["commit", "-m", "round 2's own"])

    assert {:ok, ["bill.ex", "notes.md"]} = Git.list_round_paths(task, %{base: base, merged: true})
  end

  test "a base git does not know, or a task with no repository, cannot be read", %{task: task, base: base} do
    assert {:error, :unreadable} = Git.list_round_paths(task, %{base: String.duplicate("0", 40), merged: false})
    assert {:error, :unreadable} = Git.list_round_paths(task, %{base: String.duplicate("0", 40), merged: true})

    File.rm_rf!(Task.repo_path(task))
    assert {:error, :unreadable} = Git.list_round_paths(task, %{base: base, merged: false})
  end
end
