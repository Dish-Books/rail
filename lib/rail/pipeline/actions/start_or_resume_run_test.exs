defmodule Rail.Pipeline.Actions.StartOrResumeRunTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run

  # Git is only ever asked through Rail.Git, so the worktree is only a path its fingerprint is asked of.
  setup do
    %{
      task: %{id: UXID.generate!(prefix: "tsk")},
      role: %{id: UXID.generate!(prefix: "rol")},
      worktree: Path.join(System.tmp_dir!(), "start_or_resume_run_#{System.unique_integer([:positive])}")
    }
  end

  test "creates the run on first start, stamped with the worktree fingerprint, and resumes it, keeping its history and restamping the fingerprint",
       %{task: %{id: task_id} = task, role: %{id: role_id} = role, worktree: worktree} do
    first_sha = String.duplicate("a", 40)
    second_sha = String.duplicate("b", 40)
    expect(Git, :branch_fingerprint, fn ^worktree -> %{head_sha: first_sha, dirty_digest: "clean"} end)
    expect(Git, :branch_fingerprint, fn ^worktree -> %{head_sha: second_sha, dirty_digest: "dirty"} end)

    assert {:ok,
            %Run{
              id: first_id,
              status: :running,
              task_id: ^task_id,
              role_id: ^role_id,
              started_at: %DateTime{},
              stage_fingerprint_head_sha: ^first_sha,
              stage_fingerprint_dirty_digest: "clean"
            }} = Pipeline.start_or_resume_run(task, role, worktree)

    assert {:ok, %Run{id: ^first_id, stage_fingerprint_head_sha: ^second_sha, stage_fingerprint_dirty_digest: "dirty"}} =
             Pipeline.start_or_resume_run(task, role, worktree)

    assert Repo.aggregate(Run, :count) == 1
  end

  test "leaves the fingerprint nil when git cannot answer", %{task: task, role: role, worktree: worktree} do
    expect(Git, :branch_fingerprint, fn ^worktree -> nil end)

    assert {:ok, %Run{stage_fingerprint_head_sha: nil, stage_fingerprint_dirty_digest: nil}} =
             Pipeline.start_or_resume_run(task, role, worktree)
  end

  test "keeps runs of other roles on the same task separate", %{
    task: task,
    role: role,
    worktree: worktree
  } do
    other_role = %{id: UXID.generate!(prefix: "rol")}
    stub(Git, :branch_fingerprint, fn ^worktree -> %{head_sha: String.duplicate("a", 40), dirty_digest: "clean"} end)

    {:ok, first} = Pipeline.start_or_resume_run(task, role, worktree)
    {:ok, other} = Pipeline.start_or_resume_run(task, other_role, worktree)

    assert first.id != other.id
  end
end
