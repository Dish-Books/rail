defmodule Rail.Pipeline.Actions.SaveReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_review_#{System.unique_integer([:positive])}")
    # HEAD is asked of Rail.Git, so the worktree is a plain directory and the stub says which commit it is on.
    worktree = Path.join(scratch, "worktree")
    File.mkdir_p!(worktree)
    on_exit(fn -> File.rm_rf(scratch) end)
    head = String.duplicate("a", 40)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: head, dirty_digest: "clean"} end)

    %{
      task: %Task{id: "tsk_svr", scratch_path: scratch, worktree_path: worktree, issue: %Issue{identifier: "SVR-1"}},
      head: head
    }
  end

  test "a pass is saved with its round, when, and the commit it read, and said to the page", %{
    task: %{worktree_path: worktree} = task,
    head: head
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:tsk_svr")
    expect(Git, :branch_fingerprint, fn ^worktree -> %{head_sha: head, dirty_digest: "clean"} end)

    assert Pipeline.read_review(task) == []
    assert {:ok, %{round: 1, head: ^head, finished_at: nil, saved_at: %DateTime{}}} = Pipeline.save_review(task)
    assert [%{round: 1, head: ^head}] = Pipeline.read_review(task)
    assert_received {:output_saved, "tsk_svr"}
  end

  # A round is a read of a new HEAD, so a lead saving twice on one commit has run one round.
  test "a save again at the HEAD the open pass read is that round again", %{task: task, head: head} do
    {:ok, %{round: 1, saved_at: first_saved_at}} = Pipeline.save_review(task)

    assert {:ok, %{round: 1, head: ^head, saved_at: saved_at}} = Pipeline.save_review(task)
    assert DateTime.after?(saved_at, first_saved_at)
    assert [%{round: 1, head: ^head, saved_at: ^saved_at}] = Pipeline.read_review(task)
  end

  test "a save after a new commit is the next round", %{task: task, head: head} do
    {:ok, %{round: 1}} = Pipeline.save_review(task)
    moved = String.duplicate("b", 40)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: moved, dirty_digest: "clean"} end)

    assert {:ok, %{round: 2, head: ^moved}} = Pipeline.save_review(task)
    assert [%{round: 1, head: ^head}, %{round: 2, head: ^moved}] = Pipeline.read_review(task)
  end

  # A finished review stays as it was finished, so whatever reads that commit again is a round of its own.
  test "a save at a HEAD whose pass was finished is the next round", %{task: task, head: head} do
    File.mkdir_p!(Path.join(task.scratch_path, "reviews"))
    finished_at = DateTime.utc_now()

    File.write!(
      Path.join([task.scratch_path, "reviews", "SVR-1.json"]),
      Jason.encode!(%{passes: [%{round: 1, saved_at: finished_at, head: head, finished_at: finished_at}]})
    )

    assert {:ok, %{round: 2, head: ^head, finished_at: nil}} = Pipeline.save_review(task)
    assert [%{round: 1, finished_at: ^finished_at}, %{round: 2, finished_at: nil}] = Pipeline.read_review(task)
  end

  # A comment resumes the lead at Finalize and after the merge, and nobody can rule a round opened there.
  test "past Review a save is refused and no pass is added", %{task: task} do
    for stage <- [:finalize, :merged] do
      assert {:error, {:review_finished, ^stage}} = Pipeline.save_review(%{task | stage: stage})
    end

    assert [] = Pipeline.read_review(task)
  end

  test "a worktree no longer on disk saves a pass with no commit", %{task: task} do
    reject(Git, :branch_fingerprint, 1)
    assert {:ok, %{round: 1, head: nil}} = Pipeline.save_review(%{task | worktree_path: "/nonexistent/svr"})
  end

  # Cleanup takes the review file with the scratch folder, and learnings still compare against that commit.
  test "the commit read is kept on the task's Review lead run, and on no other", %{project: project, head: head} do
    task = learnings_task(project, "SVR-2", :review)
    worktree = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(worktree)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, engineer} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, %Run{id: engineer_run_id}} =
      Pipeline.create_run(%{task_id: task.id, role_id: engineer.id, status: :finished, started_at: DateTime.utc_now()})

    {:ok, %Run{id: lead_run_id}} =
      Pipeline.create_run(%{task_id: task.id, role_id: lead.id, status: :running, started_at: DateTime.utc_now()})

    assert {:ok, %{round: 1, head: ^head}} = Pipeline.save_review(task)
    assert %Run{stage_fingerprint_head_sha: ^head} = Repo.get!(Run, lead_run_id)
    assert %Run{stage_fingerprint_head_sha: nil} = Repo.get!(Run, engineer_run_id)
  end
end
