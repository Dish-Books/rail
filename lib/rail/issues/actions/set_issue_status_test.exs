defmodule Rail.Issues.Actions.SetIssueStatusTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Roles

  @in_review %{id: "in_review", name: "In Review", state: :in_review}
  @in_progress %{id: "in_progress", name: "In Progress", state: :in_progress}
  @done %{id: "done", name: "Done", state: :done}

  setup do
    key = "Sta#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Statuses",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, parent} = Issues.create_issue(system_scope(), project, %{title: "Split me"})
    {:ok, child} = Issues.create_issue(system_scope(), project, %{title: "A part", parent: parent})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    %{local_project: project, key: key, parent: parent, child: child}
  end

  test "the status the issue already has writes nothing and broadcasts nothing", %{child: %{id: child_id} = child} do
    assert {:ok, %Issue{id: ^child_id, state: :todo}} =
             Issues.set_issue_status(system_scope(), child, %{id: "todo", name: "Todo", state: :todo})

    refute_received {:issue_changed, ^child_id}
  end

  test "two picks with the page's copy one behind both land", %{child: %{id: child_id} = child} do
    assert {:ok, %Issue{state: :in_review}} = Issues.set_issue_status(system_scope(), child, @in_review)
    assert {:ok, %Issue{state: :in_progress}} = Issues.set_issue_status(system_scope(), child, @in_progress)
    assert %Issue{state: :in_progress} = Repo.get!(Issue, child_id)
  end

  test "a scope without the project is refused", %{child: child} do
    assert {:error, :not_found} = Issues.set_issue_status(temp_user_scope(), child, @done)
  end

  test "a row deleted before the pick gives an error", %{child: child} do
    Repo.delete!(child)

    assert {:error, :not_found} = Issues.set_issue_status(system_scope(), child, @done)
  end

  test "a row deleted during the pick gives an error rather than a crash", %{child: child} do
    expect(Rail.Issues.Tracker, :set_status, fn _scope, _issue, %{state: :in_review} ->
      Repo.delete!(child)
      {:ok, %{state: :in_review, completed_at: nil}}
    end)

    assert {:error, :not_found} = Issues.set_issue_status(system_scope(), child, @in_review)
  end

  # The seeded project has the roles a run needs.
  test "a finish tells Learnings and the pipeline, and leaves the running task's stage and run unchanged", %{
    project: project
  } do
    %Issue{id: issue_id} =
      issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        identifier: "#{project.key}-#{System.unique_integer([:positive])}",
        title: "Finished while running",
        state: :in_progress
      })
      |> Repo.insert!()

    {:ok, %Task{id: task_id}} = issue |> Repo.preload(:project) |> Pipeline.create_task(:engineer)
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, %Run{id: run_id}} =
      Pipeline.create_run(%{task_id: task_id, role_id: role.id, status: :running, started_at: DateTime.utc_now()})

    expect(Pipeline, :handle_issue_finished, fn %Issue{id: ^issue_id, state: :done} -> :ok end)

    assert {:ok, %Issue{id: ^issue_id, state: :done, completed_at: %DateTime{}}} =
             Issues.set_issue_status(system_scope(), issue, @done)

    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
    assert %Task{stage: :engineer} = Repo.get!(Task, task_id)
    assert %Run{status: :running} = Repo.get!(Run, run_id)
    refute_enqueued(worker: AdvanceTrackerState)
  end

  test "Done on a split child writes Done at once, moves the split on and queues Learnings", %{
    local_project: project,
    parent: parent,
    child: %{id: child_id} = child
  } do
    {:ok, %Task{id: parent_task_id}} = Pipeline.create_task(parent, :split)

    project
    |> build_task(child, %{stage: :engineer, split_position: 1})
    |> Ecto.Changeset.put_change(:parent_task_id, parent_task_id)
    |> Repo.insert!()

    assert {:ok, %Issue{id: ^child_id, state: :done, completed_at: %DateTime{}}} =
             Issues.set_issue_status(system_scope(), child, %{id: "done", name: "Done", state: :done})

    assert %Issue{state: :done, completed_at: %DateTime{}} = Repo.get!(Issue, child_id)
    assert_receive {:issue_changed, ^child_id}
    assert_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent_task_id})
    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: child_id})
    refute_enqueued(worker: SyncIssue)
  end

  test "a move into Done waits for testing, and a Tested ticket reopened and done again stays Tested with its notes",
       %{child: child} do
    done = %{id: "done", name: "Done", state: :done}
    in_progress = %{id: "in_progress", name: "In Progress", state: :in_progress}

    assert {:ok, %Issue{state: :done, testing_state: :waiting} = waiting} =
             Issues.set_issue_status(system_scope(), child, done)

    {:ok, _noted} = Issues.save_testing_notes(system_scope(), waiting, "Looked fine")
    {:ok, tested} = Issues.mark_issue_tested(system_scope(), waiting)

    assert {:ok, %Issue{state: :in_progress, testing_state: :tested, testing_notes: "Looked fine"} = reopened} =
             Issues.set_issue_status(system_scope(), tested, in_progress)

    assert {:ok, %Issue{state: :done, testing_state: :tested, testing_notes: "Looked fine"}} =
             Issues.set_issue_status(system_scope(), reopened, done)
  end

  test "canceling a Waiting ticket takes it out of the queue", %{child: %{id: child_id} = child} do
    {:ok, waiting} = Issues.set_issue_status(system_scope(), child, %{id: "done", name: "Done", state: :done})

    assert {:ok, %Issue{id: ^child_id, state: :canceled} = canceled} =
             Issues.set_issue_status(system_scope(), waiting, %{id: "canceled", name: "Canceled", state: :canceled})

    refute Issue.in_testing_queue?(canceled)
    %{issues: queue} = Issues.list_issues(project_id: child.project_id, testing: true)
    refute Enum.any?(queue, &(&1.id == child_id))
  end

  test "a move out of Done clears the completed time and tells nobody again", %{child: %{id: child_id} = child} do
    {:ok, done} = Issues.set_issue_status(system_scope(), child, %{id: "done", name: "Done", state: :done})

    assert {:ok, %Issue{id: ^child_id, state: :in_progress, completed_at: nil}} =
             Issues.set_issue_status(system_scope(), done, %{
               id: "in_progress",
               name: "In Progress",
               state: :in_progress
             })

    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: child_id})
  end

  test "an issue moved to In Progress or In Review joins the running cycle from none, an upcoming or an ended one",
       %{local_project: project} do
    # Cycle 1 ran Nov 10 to 23 and kept the issue finished in it; Cycle 2 runs now and Cycle 3 is next.
    :ok = Issues.close_cycle_day(~D[2026-11-10])

    [first, %{id: second_id}, third] =
      Repo.all(from(c in Cycle, where: c.project_id == ^project.id, order_by: c.number))

    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)
    {:ok, ended} = Issues.create_issue(system_scope(), project, %{title: "Finished in Cycle 1"})
    {:ok, ended} = Issues.set_issue_cycle(system_scope(), ended, first.id)
    {:ok, ended} = Issues.set_issue_status(system_scope(), ended, %{id: "done", name: "Done", state: :done})
    :ok = Issues.close_cycle_day(~D[2026-11-24])
    stub(Date, :utc_today, fn -> ~D[2026-11-25] end)

    {:ok, none} = Issues.create_issue(system_scope(), project, %{title: "In no cycle"})
    {:ok, upcoming} = Issues.create_issue(system_scope(), project, %{title: "Planned for Cycle 3"})
    {:ok, upcoming} = Issues.set_issue_cycle(system_scope(), upcoming, third.id)
    in_progress = %{id: "in_progress", name: "In Progress", state: :in_progress}

    for issue <- [none, upcoming, ended] do
      assert {:ok, %Issue{state: :in_progress, cycle_id: ^second_id}} =
               Issues.set_issue_status(system_scope(), issue, in_progress)
    end

    {:ok, reviewed} = Issues.create_issue(system_scope(), project, %{title: "Straight to review"})

    assert {:ok, %Issue{state: :in_review, cycle_id: ^second_id}} =
             Issues.set_issue_status(system_scope(), reviewed, %{id: "in_review", name: "In Review", state: :in_review})
  end

  test "with no cycle running, an issue that starts keeps its cycle", %{local_project: project, parent: parent} do
    :ok = Issues.close_cycle_day(~D[2026-11-10])

    [_first, %{id: second_id} | _later] =
      Repo.all(from(c in Cycle, where: c.project_id == ^project.id, order_by: c.number))

    stub(Date, :utc_today, fn -> ~D[2026-11-09] end)
    {:ok, parent} = Issues.set_issue_cycle(system_scope(), parent, second_id)

    assert {:ok, %Issue{state: :in_progress, cycle_id: ^second_id}} =
             Issues.set_issue_status(system_scope(), parent, %{
               id: "in_progress",
               name: "In Progress",
               state: :in_progress
             })
  end
end
