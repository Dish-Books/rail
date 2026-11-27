defmodule Rail.Git.Actions.CheckPushRefsTest do
  use ExUnit.Case, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  @old String.duplicate("1", 40)
  @new String.duplicate("2", 40)
  @zero String.duplicate("0", 40)

  setup do
    %{task: %Task{id: "tsk_refs", worktree_name: "feature"}}
  end

  test "lets a push update the task's branch, its wip snapshot and CI receipts", %{task: task} do
    assert :ok =
             Git.check_push_refs(task, [
               {@old, @new, "refs/heads/feature"},
               {@zero, @new, "refs/rail/wip"},
               {@old, @zero, "refs/rail/wip"},
               {@zero, @new, "refs/ci-receipts/#{String.duplicate("a", 40)}"}
             ])

    assert :ok = Git.check_push_refs(task, [])
    assert :ok = Git.check_push_refs(%{task | worktree_name: nil}, [{@old, @new, "refs/heads/tsk_refs"}])
  end

  test "refuses the first ref it may not update", %{task: task} do
    assert {:error, "refs/heads/main"} =
             Git.check_push_refs(task, [{@old, @new, "refs/heads/feature"}, {@old, @new, "refs/heads/main"}])

    assert {:error, "refs/remotes/origin/feature"} =
             Git.check_push_refs(task, [{@old, @new, "refs/remotes/origin/feature"}])

    assert {:error, "refs/ci-receipts/../heads/main"} =
             Git.check_push_refs(task, [{@old, @new, "refs/ci-receipts/../heads/main"}])

    assert {:error, "refs/tags/v1"} = Git.check_push_refs(task, [{@zero, @new, "refs/tags/v1"}])
  end

  test "refuses deleting the task's branch", %{task: task} do
    assert {:error, "refs/heads/feature"} = Git.check_push_refs(task, [{@old, @zero, "refs/heads/feature"}])
  end
end
