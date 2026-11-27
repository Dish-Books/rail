defmodule Rail.Git.Actions.SyncCheckoutTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools

  setup do
    create_task_checkout()
  end

  test "pushes the checkout's branch, its receipts and a snapshot of its uncommitted work into the repository", %{
    task: task,
    repo: repo,
    checkout: checkout
  } do
    git!(checkout, ["commit", "--allow-empty", "-m", "the work"])
    head = String.trim(git!(checkout, ["rev-parse", "HEAD"]))
    tree = String.trim(git!(checkout, ["rev-parse", "HEAD^{tree}"]))
    git!(checkout, ["update-ref", "refs/ci-receipts/#{tree}", head])
    File.write!(Path.join(checkout, "tracked.txt"), "edited\n")
    File.write!(Path.join(checkout, "new.ex"), "new\n")
    File.write!(Path.join(checkout, ".gitignore"), "ignored.log\n")
    File.write!(Path.join(checkout, "ignored.log"), "noise\n")
    git!(checkout, ["add", "new.ex"])

    assert :ok = Git.sync_checkout(task)

    assert git!(repo, ["rev-parse", "refs/heads/#{task.worktree_name}"]) == head <> "\n"
    assert git!(repo, ["rev-parse", "refs/ci-receipts/#{tree}"]) == head <> "\n"
    assert git!(repo, ["rev-parse", "refs/rail/wip^"]) == head <> "\n"
    assert git!(repo, ["show", "refs/rail/wip:tracked.txt"]) == "edited\n"
    assert git!(repo, ["ls-tree", "--name-only", "refs/rail/wip"]) == ".gitignore\nnew.ex\ntracked.txt\n"
    # The checkout's own index is as the agent left it.
    assert checkout |> git!(["status", "--porcelain"]) |> String.split("\n", trim: true) |> Enum.sort() == [
             " M tracked.txt",
             "?? .gitignore",
             "A  new.ex"
           ]
  end

  test "moves the branch wherever the checkout's went, rewritten or not", %{task: task, repo: repo, checkout: checkout} do
    git!(checkout, ["commit", "--allow-empty", "-m", "the work"])
    assert :ok = Git.sync_checkout(task)
    git!(checkout, ["commit", "--amend", "--allow-empty", "-m", "the work, reworded"])

    assert :ok = Git.sync_checkout(task)
    assert git!(repo, ["log", "-1", "--format=%s", "refs/heads/#{task.worktree_name}"]) == "the work, reworded\n"
  end

  test "a sync started within the window counts, unless the caller wants it fresh", %{task: task, checkout: checkout} do
    stub(Rail, :checkout_sync_ms, fn -> 60_000 end)
    assert :ok = Git.sync_checkout(task)
    File.write!(Path.join(checkout, "new.ex"), "new\n")

    assert Git.list_changed_paths(task) == []

    assert :ok = Git.sync_checkout(task, fresh: true)
    assert Git.list_changed_paths(task) == ["new.ex"]
  end

  test "a task with no checkout on Rail's disk has nothing to sync", %{task: task} do
    File.rm_rf!(task.worktree_path)

    assert :ok = Git.sync_checkout(task)
  end

  test "says what git said when the checkout cannot be synced", %{task: task, checkout: checkout} do
    File.rm_rf!(Task.repo_path(task))
    assert {:error, output} = Git.sync_checkout(task)
    assert output =~ "does not appear to be a git repository"

    git!(checkout, ["checkout", "--quiet", "--orphan", "unborn"])
    assert {:error, _unborn} = Git.sync_checkout(task)
  end

  describe "under the docker runtime" do
    setup do
      stub(Rail, :sandbox_runtime, fn -> :docker end)
      :ok
    end

    test "asks the sandbox to sync, at the checkout's path and on the task's branch", %{
      task: %{worktree_path: path, worktree_name: branch} = task
    } do
      expect(Tools, :call_sandbox, fn ^task, "sync", %{"path" => ^path, "branch" => ^branch} ->
        {:ok, %{"head" => "abc", "wip" => "def"}}
      end)

      assert :ok = Git.sync_checkout(task)
    end

    test "a stopped sandbox synced before it stopped, and a refused call says why", %{task: task, checkout: checkout} do
      assert :ok = Git.sync_checkout(task)
      # Its work is read as it last synced: here, never, so the branch alone stands for it.
      File.write!(Path.join(checkout, "new.ex"), "new\n")
      refute Git.worktree_dirty?(task)

      stub(Tools, :call_sandbox, fn _task, "sync", _params -> {:error, :timeout} end)
      assert {:error, :timeout} = Git.sync_checkout(task)
    end
  end
end
