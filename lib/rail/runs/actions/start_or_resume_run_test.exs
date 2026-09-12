defmodule Rail.Runs.Actions.StartOrResumeRunTest do
  use Rail.DataCase, async: true

  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  setup do
    worktree = create_temp_git_repo(prefix: "start_or_resume_run")

    %{
      task: %{id: UXID.generate!(prefix: "tsk")},
      role: %{id: UXID.generate!(prefix: "rol")},
      worktree: worktree
    }
  end

  test "creates the run on first start, stamped with the worktree fingerprint", %{
    task: task,
    role: role,
    worktree: worktree
  } do
    assert {:ok, run} = Runs.start_or_resume_run(task, role, worktree)

    assert %Run{status: :running, attempts: 1} = run
    assert run.task_id == task.id
    assert run.role_id == role.id
    assert run.started_at
    assert run.stage_fingerprint_head_sha == head_sha(worktree)
    assert is_binary(run.stage_fingerprint_dirty_digest)
  end

  test "resumes the existing run, bumping attempts and restamping the fingerprint", %{
    task: task,
    role: role,
    worktree: worktree
  } do
    {:ok, first} = Runs.start_or_resume_run(task, role, worktree)

    File.write!(Path.join(worktree, "tracked.txt"), "changed\n")
    git!(worktree, ["commit", "-am", "second"])

    {:ok, second} = Runs.start_or_resume_run(task, role, worktree)

    assert second.id == first.id
    assert second.attempts == 2
    assert second.stage_fingerprint_head_sha == head_sha(worktree)
    assert second.stage_fingerprint_head_sha != first.stage_fingerprint_head_sha
    assert Repo.aggregate(Run, :count) == 1
  end

  test "leaves .rail/ changes out of the dirty digest", %{
    task: task,
    role: role,
    worktree: worktree
  } do
    {:ok, before} = Runs.start_or_resume_run(task, role, worktree)

    File.mkdir_p!(Path.join(worktree, ".rail"))
    File.write!(Path.join([worktree, ".rail", "notes.md"]), "scratch\n")

    {:ok, after_rail_write} = Runs.start_or_resume_run(task, role, worktree)

    assert after_rail_write.stage_fingerprint_dirty_digest ==
             before.stage_fingerprint_dirty_digest

    File.write!(Path.join(worktree, "tracked.txt"), "edited\n")

    {:ok, after_code_write} = Runs.start_or_resume_run(task, role, worktree)

    refute after_code_write.stage_fingerprint_dirty_digest ==
             before.stage_fingerprint_dirty_digest
  end

  test "leaves the fingerprint nil when git cannot answer", %{task: task, role: role} do
    non_repo = Path.join(System.tmp_dir!(), "sorrr_missing_#{System.unique_integer([:positive])}")

    assert {:ok, run} = Runs.start_or_resume_run(task, role, non_repo)
    assert run.stage_fingerprint_head_sha == nil
    assert run.stage_fingerprint_dirty_digest == nil
  end

  test "keeps runs of other roles on the same task separate", %{
    task: task,
    role: role,
    worktree: worktree
  } do
    other_role = %{id: UXID.generate!(prefix: "rol")}

    {:ok, first} = Runs.start_or_resume_run(task, role, worktree)
    {:ok, other} = Runs.start_or_resume_run(task, other_role, worktree)

    assert first.id != other.id
    assert other.attempts == 1
  end

  defp head_sha(worktree) do
    {out, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: worktree)
    String.trim(out)
  end
end
