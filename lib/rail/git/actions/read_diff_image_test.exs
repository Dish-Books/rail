defmodule Rail.Git.Actions.ReadDiffImageTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline

  setup %{project: project} do
    remote = create_temp_git_repo(prefix: "rail_read_diff_image_remote")
    File.write!(Path.join(remote, "logo.png"), "old png")
    File.write!(Path.join(remote, "notes.txt"), "notes\n")
    git!(remote, ["add", "."])
    git!(remote, ["commit", "-m", "logo"])

    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["fetch", "origin", "main"])
    git!(repo, ["reset", "--hard", "origin/main"])
    git!(repo, ["checkout", "-b", "feature"])
    File.write!(Path.join(repo, "logo.png"), "committed png")
    git!(repo, ["commit", "-am", "new logo"])
    File.write!(Path.join(repo, "logo.png"), "worktree png")

    task = learnings_task(project, "RDI-1", :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, repo: repo}
  end

  test "the branch's old side is the base's picture and its new side the worktree's", %{task: task} do
    assert {:ok, "image/png", "old png"} = Git.read_diff_image(task, "logo.png", :old, :branch)
    assert {:ok, "image/png", "worktree png"} = Git.read_diff_image(task, "logo.png", :new, :branch)
  end

  test "the uncommitted view's old side is HEAD's", %{task: task} do
    assert {:ok, "image/png", "committed png"} = Git.read_diff_image(task, "logo.png", :old, :uncommitted)
  end

  test "a commit's sides are its parent's picture and its own", %{task: task, repo: repo} do
    sha = repo |> git!(["rev-parse", "HEAD"]) |> String.trim()

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

  test "reads nothing once the worktree is gone", %{task: task, repo: repo} do
    File.rm_rf!(repo)

    assert {:error, :not_found} = Git.read_diff_image(task, "logo.png", :new, :branch)
  end
end
