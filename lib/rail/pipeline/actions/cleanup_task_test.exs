defmodule Rail.Pipeline.Actions.CleanupTaskTest do
  use Rail.DataCase, async: false

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "refuses to clean up when task is busy" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :engineer,
          stage_state: :running
      })

    assert {:error, :task_busy} = Pipeline.cleanup_task(task)

    task_chat =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :qa,
          stage_state: :awaiting_approval,
          active_chat_role_id: "qa"
      })

    assert {:error, :task_busy} = Pipeline.cleanup_task(task_chat)
  end

  test "cleans up worktree, branch, scratch directory, updates worktree_path to nil, and broadcasts" do
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline:changed")
    clone_path = create_temp_git_repo(prefix: "rail_cleanup_main")
    wt_dir = Path.join(System.tmp_dir!(), "rail_cleanup_wt_#{System.unique_integer([:positive])}")
    {:ok, worktree_path} = Git.get_or_create_worktree(clone_path, wt_dir, "cleanup-branch")

    project =
      Repo.insert!(%{
        Project.factory()
        | clone_path: clone_path
      })

    scratch_dir = Path.join(System.tmp_dir!(), "rail_cleanup_scratch_#{System.unique_integer([:positive])}")
    File.mkdir_p!(scratch_dir)
    File.write!(Path.join(scratch_dir, "scratch.txt"), "temporary content")

    user = Repo.insert!(User.factory())
    scope = Scope.for_user(user)

    %Task{id: task_id} =
      task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :merged,
          stage_state: :queued,
          worktree_name: "cleanup-branch",
          worktree_path: worktree_path
      })

    assert {:ok, %Task{worktree_path: nil}} =
             Pipeline.cleanup_task(scope, task, scratch_dir: scratch_dir)

    refute File.exists?(worktree_path)
    refute File.exists?(scratch_dir)

    assert_receive {:pipeline_changed, %{task_id: ^task_id, event: :task_cleaned_up}}
  end

  test "handles cleanup gracefully when worktree_path is already nil" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :merged,
          worktree_name: nil,
          worktree_path: nil
      })

    assert {:ok, %Task{worktree_path: nil}} = Pipeline.cleanup_task(task)
  end

  test "returns error when scope is unauthorized" do
    assert {:error, :not_authorized} = Pipeline.cleanup_task(:unauthorized, "tsk_123")
  end

  test "returns error when task is not found" do
    assert {:error, :not_found} = Pipeline.cleanup_task("tsk_nonexistent")
    assert {:error, :not_found} = Pipeline.cleanup_task(123)
  end

  test "accepts nil scope and task with opts" do
    project = Repo.insert!(Project.factory())

    task =
      Repo.insert!(%{
        Task.factory()
        | project_id: project.id,
          stage: :merged,
          worktree_name: nil,
          worktree_path: nil
      })

    assert {:ok, %Task{worktree_path: nil}} = Pipeline.cleanup_task(nil, task)
    assert {:ok, %Task{worktree_path: nil}} = Pipeline.cleanup_task(task.id, scratch_dir: "/tmp/nonexistent")
  end
end
