defmodule Rail.Git.Actions.ReadDiffImageTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline.Schemas.Task

  setup do
    %{remote: remote, checkout: checkout} = context = create_task_checkout()
    File.write!(Path.join(remote, "logo.png"), "old png")
    File.write!(Path.join(remote, "notes.txt"), "notes\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "logo"])
    :ok = Git.fetch_default_branch(context.project, context.task)
    git!(checkout, ["merge", "--quiet", "origin/main"])

    File.write!(Path.join(checkout, "logo.png"), "committed png")
    git!(checkout, ["commit", "-am", "new logo"])
    File.write!(Path.join(checkout, "logo.png"), "worktree png")

    context
  end

  test "the branch's old side is the base's picture and its new side the checkout's", %{task: task} do
    assert {:ok, "image/png", "old png"} = Git.read_diff_image(task, "logo.png", :old, :branch)
    assert {:ok, "image/png", "worktree png"} = Git.read_diff_image(task, "logo.png", :new, :branch)
  end

  test "the uncommitted view's old side is the branch head's", %{task: task} do
    assert {:ok, "image/png", "committed png"} = Git.read_diff_image(task, "logo.png", :old, :uncommitted)
  end

  test "a commit's sides are its parent's picture and its own", %{task: task, checkout: checkout} do
    sha = checkout |> git!(["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok, "image/png", "old png"} = Git.read_diff_image(task, "logo.png", :old, {:commit, sha})
    assert {:ok, "image/png", "committed png"} = Git.read_diff_image(task, "logo.png", :new, {:commit, sha})
  end

  # The path and the sha come from a page.
  test "reads nothing but a picture, at nothing but a commit name", %{task: task} do
    assert {:error, :not_found} = Git.read_diff_image(task, "notes.txt", :new, :branch)
    assert {:error, :not_found} = Git.read_diff_image(task, "../logo.png", :new, :branch)
    assert {:error, :not_found} = Git.read_diff_image(task, "missing.png", :old, :branch)
    assert {:error, :not_found} = Git.read_diff_image(task, "logo.png", :new, {:commit, "--output=x"})
    assert {:error, :not_found} = Git.read_diff_image(task, "logo.png", :new, :elsewhere)
  end

  test "reads nothing once the task's repository is gone", %{task: task} do
    File.rm_rf!(Task.repo_path(task))

    assert {:error, :not_found} = Git.read_diff_image(task, "logo.png", :new, :branch)
  end
end
