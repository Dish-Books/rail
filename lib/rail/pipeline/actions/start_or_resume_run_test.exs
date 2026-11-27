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
    expect(Git, :branch_fingerprint, fn %{worktree_path: ^worktree} -> %{head_sha: first_sha, dirty_digest: "clean"} end)
    expect(Git, :branch_fingerprint, fn %{worktree_path: ^worktree} -> %{head_sha: second_sha, dirty_digest: "dirty"} end)

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

  # CI stops sending its failures back after three in a row. A Retry is a person stepping in, so a run started again
  # has its next failure sent back rather than stopping it on the spot.
  test "a run started again counts its CI failures from none", %{task: task, role: role, worktree: worktree} do
    stub(Git, :branch_fingerprint, fn %{worktree_path: ^worktree} -> nil end)
    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree)

    {:ok, _stopped} =
      run
      |> Run.changeset(%{status: :finished, ci_failure_streak: 3, error: "CI failed 3 times in a row."})
      |> Repo.update()

    assert {:ok, %Run{ci_failure_streak: 0, error: nil}} = Pipeline.start_or_resume_run(task, role, worktree)
  end

  test "leaves the fingerprint nil when git cannot answer", %{task: task, role: role, worktree: worktree} do
    expect(Git, :branch_fingerprint, fn %{worktree_path: ^worktree} -> nil end)

    assert {:ok, %Run{stage_fingerprint_head_sha: nil, stage_fingerprint_dirty_digest: nil}} =
             Pipeline.start_or_resume_run(task, role, worktree)
  end

  test "keeps runs of other roles on the same task separate", %{
    task: task,
    role: role,
    worktree: worktree
  } do
    other_role = %{id: UXID.generate!(prefix: "rol")}

    stub(Git, :branch_fingerprint, fn %{worktree_path: ^worktree} ->
      %{head_sha: String.duplicate("a", 40), dirty_digest: "clean"}
    end)

    {:ok, first} = Pipeline.start_or_resume_run(task, role, worktree)
    {:ok, other} = Pipeline.start_or_resume_run(task, other_role, worktree)

    assert first.id != other.id
  end
end
