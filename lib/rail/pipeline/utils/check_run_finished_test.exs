defmodule Rail.Pipeline.Utils.CheckRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.CheckRunFinished

  alias Rail.Git
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    task = learnings_task(project, "CRF-1", :review)
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: create_temp_git_repo()})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    round = Repo.insert!(%Round{task_id: task.id, number: 1, plan: "Filter.", approved_at: DateTime.utc_now()})

    stub(Git, :get_or_create_worktree, fn _project, _task -> {:ok, task.worktree_path} end)
    test_pid = self()

    # Each start says which agent it was, so a test sees what a finish started and what it did not.
    stub(Tools, :start_os_process, fn %Run{} = spawned, argv ->
      send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage, "--resume" in argv})
      {:ok, %OsProcess{run: spawned}}
    end)

    runs =
      Map.new([:qa, :review], fn stage ->
        {:ok, role} = Roles.get_role(project_id: project.id, stage: stage)

        {:ok, run} =
          Pipeline.create_run(%{
            task_id: task.id,
            role_id: role.id,
            status: :finished,
            conversation_id: "sess_crf_#{stage}",
            started_at: DateTime.utc_now()
          })

        {stage, Repo.preload(run, [:task, :role])}
      end)

    %{task: task, round: round, runs: runs}
  end

  test "QA or the code reviewer that saved no report says so, latches nothing and starts nothing", %{runs: runs} do
    assert %Run{error: "QA did not save its report.", stage_outcome: :in_progress} = check_run_finished(runs.qa, [])

    assert %Run{error: "The code reviewer did not save its report."} = check_run_finished(runs.review, [])
    refute_received {:started, _stage, _resumed}
  end

  # Every check started together, so a finish starts no other check.
  test "QA's finish while the others still work latches it done and starts nothing", %{task: task, runs: runs} do
    {:ok, _saved} = Pipeline.save_report(task, :qa, "Two rows.")

    assert %Run{stage_outcome: :done, error: nil} = check_run_finished(runs.qa, [])
    refute_received {:started, _stage, _resumed}
  end

  test "the last of QA and the code reviewer to finish starts the review agent", %{task: task, runs: runs} do
    {:ok, _saved} = Pipeline.save_report(task, :qa, "Two rows.")
    {:ok, _saved} = Pipeline.save_report(task, :review, "Nothing to report.")

    assert %Run{stage_outcome: :done} = check_run_finished(runs.review, [])
    refute_received {:started, _stage, _resumed}

    assert %Run{stage_outcome: :done} = check_run_finished(runs.qa, [])
    assert_received {:started, :review_lead, false}
    refute_received {:started, _stage, _resumed}
  end

  # The demo started beside the others, and the review agent does not wait on it.
  test "a round whose plan asks for a demo starts the review agent without it", %{
    task: task,
    round: round,
    runs: runs
  } do
    round |> Ecto.Changeset.change(record_demo: true) |> Repo.update!()
    {:ok, _saved} = Pipeline.save_report(task, :qa, "Two rows.")
    {:ok, _saved} = Pipeline.save_report(task, :review, "Nothing to report.")
    %Run{} = check_run_finished(runs.qa, [])
    %Run{} = check_run_finished(runs.review, [])
    assert_received {:started, :review_lead, false}
    refute_received {:started, _stage, _resumed}
  end

  # A role the project does not have checks nothing, so nothing waits on it.
  test "with no code reviewer role, QA starts the review agent alone", %{task: task, runs: runs} do
    Repo.delete!(runs.review)
    Repo.delete!(runs.review.role)
    {:ok, _saved} = Pipeline.save_report(task, :qa, "Two rows.")

    assert %Run{stage_outcome: :done} = check_run_finished(runs.qa, [])
    assert_received {:started, :review_lead, false}
    refute_received {:started, _stage, _resumed}
  end

  # A task sent to Engineer with no plan has nothing asking for a demo.
  test "a task with no plan has QA and the code reviewer start the review agent alone", %{
    task: task,
    round: round,
    runs: runs
  } do
    Repo.delete!(round)
    {:ok, _saved} = Pipeline.save_report(task, :qa, "Two rows.")
    {:ok, _saved} = Pipeline.save_report(task, :review, "Nothing to report.")
    %Run{} = check_run_finished(runs.qa, [])
    %Run{} = check_run_finished(runs.review, [])

    assert_received {:started, :review_lead, false}
    refute_received {:started, _stage, _resumed}
  end
end
