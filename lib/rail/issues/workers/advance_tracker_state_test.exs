defmodule Rail.Issues.Workers.AdvanceTrackerStateTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Tracker
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects
  alias Rail.Repo

  @todo %{id: "todo", name: "Todo", state: :todo}
  @in_progress %{id: "in_progress", name: "In Progress", state: :in_progress}

  # A cleaned-up task's worktree and branch are removed from the project's clone through Rail.Git.
  setup do
    stub(Rail.Git, :remove_worktree, fn _clone_path, _worktree_path -> :ok end)
    stub(Rail.Git, :delete_branch, fn _clone_path, _branch -> :ok end)

    :ok
  end

  setup do
    key = "Adv#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Advanced",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, %Issue{owner_user_id: nil} = issue} = Issues.create_issue(system_scope(), project, %{title: "Unowned"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    %{project: project, issue: issue, task: task}
  end

  test "follows its task with nobody owning it: In Progress at Plan, In Review at Review, Done at Merged", %{
    issue: %{id: issue_id},
    task: task
  } do
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :in_progress, completed_at: nil} = Repo.get!(Issue, issue_id)
    assert_receive {:issue_changed, ^issue_id}
    refute_enqueued(worker: IssueFinished)

    {:ok, task} = Pipeline.update_task(task, %{stage: :review})
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :in_review} = Repo.get!(Issue, issue_id)
    assert_receive {:issue_changed, ^issue_id}

    {:ok, _task} = Pipeline.update_task(task, %{stage: :merged})
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :done, completed_at: %DateTime{}} = Repo.get!(Issue, issue_id)
    assert_receive {:issue_changed, ^issue_id}
    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
  end

  test "Start puts an issue in no cycle in the running one as it moves it to In Progress", %{
    project: project,
    issue: %{id: issue_id}
  } do
    :ok = Issues.close_cycle_day(Date.utc_today())

    [%Cycle{id: running_id} | _later] =
      Repo.all(from(c in Cycle, where: c.project_id == ^project.id, order_by: c.number))

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :in_progress, cycle_id: ^running_id} = Repo.get!(Issue, issue_id)
  end

  test "never moves back, so the engineer leaves In Review where it is", %{issue: %{id: issue_id} = issue, task: task} do
    {:ok, _review} =
      Issues.set_issue_status(system_scope(), issue, %{id: "in_review", name: "In Review", state: :in_review})

    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :in_review} = Repo.get!(Issue, issue_id)
  end

  test "a move that fails returns its error, for Oban to try again", %{issue: %{id: issue_id}, task: task} do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
    expect(Tracker, :advance_issue, fn %Issue{id: ^issue_id}, :in_progress -> {:error, :not_found} end)

    assert {:error, :not_found} = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
  end

  test "a canceled issue stays canceled when its task merges", %{issue: %{id: issue_id} = issue, task: task} do
    {:ok, _canceled} =
      Issues.set_issue_status(system_scope(), issue, %{id: "canceled", name: "Canceled", state: :canceled})

    {:ok, _task} = Pipeline.update_task(task, %{stage: :merged})

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :canceled, completed_at: nil} = Repo.get!(Issue, issue_id)
    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
  end

  test "a split child reaching Done moves its parent's split on", %{project: project, issue: parent_issue, task: task} do
    Repo.delete!(task)
    {:ok, %Task{id: parent_task_id}} = Pipeline.create_task(parent_issue, :split)

    {:ok, %Issue{id: child_id} = child} =
      Issues.create_issue(system_scope(), project, %{title: "A part", parent: parent_issue})

    project
    |> build_task(child, %{stage: :merged, split_position: 1})
    |> Ecto.Changeset.put_change(:parent_task_id, parent_task_id)
    |> Repo.insert!()

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: child_id})
    assert %Issue{state: :done} = Repo.get!(Issue, child_id)
    assert_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent_task_id})
    assert_enqueued(worker: IssueFinished, args: %{issue_id: child_id})
  end

  test "Plan, a custom stage and the engineer move a Todo issue to In Progress, and Finalize moves it to In Review", %{
    issue: %{id: issue_id} = issue,
    task: task
  } do
    for stage <- [:plan, :custom, :engineer] do
      {:ok, _todo} = Issues.set_issue_status(system_scope(), Repo.get!(Issue, issue_id), @todo)
      {:ok, _task} = Pipeline.update_task(task, %{stage: stage, custom_stage: "License check"})

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
      assert %Issue{state: :in_progress} = Repo.get!(Issue, issue_id)
    end

    {:ok, _task} = Pipeline.update_task(task, %{stage: :finalize})
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
    assert %Issue{state: :in_review} = Repo.get!(Issue, issue_id)
  end

  # Two jobs running together must not let the earlier stage's write land last.
  test "a job queued at the engineer stage aims at In Review once the task has moved to review", %{
    issue: %{id: issue_id} = issue,
    task: task
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})
    {:ok, %Oban.Job{args: args}} = Issues.advance_issue_state(issue)
    {:ok, _task} = Pipeline.update_task(task, %{stage: :review})

    assert :ok = perform_job(AdvanceTrackerState, args)
    assert %Issue{state: :in_review} = Repo.get!(Issue, issue_id)
  end

  # The stage entered mid-run was refused a job of its own, because this one was executing.
  test "a job whose task moves on while it writes runs again for the new stage", %{issue: issue, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :engineer})

    expect(Tracker, :advance_issue, fn %Issue{} = advanced, :in_progress ->
      {:ok, _task} = Pipeline.update_task(task, %{stage: :review})
      Mimic.call_original(Tracker, :advance_issue, [advanced, :in_progress])
    end)

    assert {:snooze, 1} = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
  end

  test "a job that had nothing to move still runs again when its task moves on meanwhile", %{
    issue: %{id: issue_id} = issue,
    task: task
  } do
    {:ok, _started} = Issues.set_issue_status(system_scope(), issue, @in_progress)

    expect(Tracker, :advance_issue, fn %Issue{} = advanced, :in_progress ->
      {:ok, _task} = Pipeline.update_task(task, %{stage: :engineer})
      Mimic.call_original(Tracker, :advance_issue, [advanced, :in_progress])
    end)

    assert {:snooze, 1} = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :in_progress} = Repo.get!(Issue, issue_id)
  end

  test "an issue with no task, or a task at a stage the issue does not follow, stays where it is", %{
    issue: %{id: issue_id, state: state},
    task: task
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :split})
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: ^state} = Repo.get!(Issue, issue_id)

    Repo.delete!(task)
    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: ^state} = Repo.get!(Issue, issue_id)
  end

  test "an issue whose task was cleaned up short of Merged stays where it is", %{
    issue: %{id: issue_id, state: state},
    task: task
  } do
    for stage <- [:engineer, :review] do
      {:ok, _task} = Pipeline.update_task(task, %{stage: stage, cleaned_up_at: DateTime.utc_now()})

      assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
      assert %Issue{state: ^state} = Repo.get!(Issue, issue_id)
    end
  end

  # The merge queues its cleanup too, and that job can finish first.
  test "a merged task cleaned up before this runs still moves its issue to Done", %{
    issue: %{id: issue_id},
    task: task
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})
    {:ok, _cleaned} = Pipeline.cleanup_task(task)

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :done} = Repo.get!(Issue, issue_id)
  end

  # An issue started again after a cleanup follows its new task, not the one before it.
  test "an issue started again after a merged task was cleaned up follows the new task", %{
    issue: %{id: issue_id} = issue,
    task: task
  } do
    {:ok, task} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})
    {:ok, _cleaned} = Pipeline.cleanup_task(task)
    {:ok, _again} = Pipeline.create_task(issue, :plan)

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :in_progress} = Repo.get!(Issue, issue_id)
  end

  test "an issue reopened after a merge, whose new task was cleaned up short of Merged, stays where it is", %{
    issue: %{id: issue_id, state: state} = issue,
    task: task
  } do
    {:ok, merged} = Pipeline.update_task(task, %{stage: :merged, merged_at: DateTime.utc_now()})

    # Backdated so the abandoned task is the newer one whatever the clock does between inserts.
    merged =
      merged |> Ecto.Changeset.change(inserted_at: DateTime.shift(merged.inserted_at, hour: -1)) |> Repo.update!()

    {:ok, _cleaned} = Pipeline.cleanup_task(merged)
    {:ok, abandoned} = Pipeline.create_task(issue, :plan)
    {:ok, abandoned} = Pipeline.update_task(abandoned, %{stage: :engineer})
    {:ok, _cleaned} = Pipeline.cleanup_task(abandoned)

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: ^state} = Repo.get!(Issue, issue_id)
  end

  test "an issue that is gone needs no move", %{issue: issue} do
    Repo.delete!(issue)

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue.id})
  end
end
