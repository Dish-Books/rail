defmodule Rail.Issues.Actions.HandleGithubWebhookTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects

  setup do
    key = "Prm#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Merged into",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Merged outside Rail"})
    {:ok, task} = Pipeline.create_task(issue, :plan)
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    closed = fn merged, number, head, base ->
      %{
        "action" => "closed",
        "pull_request" => %{
          "merged" => merged,
          "number" => number,
          "head" => %{"ref" => head},
          "base" => %{"ref" => base}
        }
      }
    end

    %{project: project, issue: issue, task: task, closed: closed}
  end

  test "a task's pull request merged on GitHub moves its issue to Done and leaves the task where it is", %{
    project: project,
    issue: %{id: issue_id},
    task: task,
    closed: closed
  } do
    {:ok, %Task{id: task_id}} = Pipeline.update_task(task, %{stage: :finalize, pr_number: 41})

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 41, "elsewhere", "main"))

    assert %Issue{state: :done, completed_at: %DateTime{}} = Repo.get!(Issue, issue_id)
    assert_receive {:issue_changed, ^issue_id}
    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
    assert %Task{stage: :finalize, cleaned_up_at: nil} = Repo.get!(Task, task_id)
  end

  test "a merge delivered twice for a cleaned-up task finishes the issue once", %{
    project: project,
    issue: %{id: issue_id},
    task: task,
    closed: closed
  } do
    {:ok, _task} = Pipeline.update_task(task, %{pr_number: 42, cleaned_up_at: DateTime.utc_now(:second)})
    expect(Pipeline, :handle_issue_finished, 1, fn %Issue{id: ^issue_id, state: :done} -> :ok end)

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 42, "elsewhere", "main"))
    assert %Issue{state: :done} = Repo.get!(Issue, issue_id)

    first_write = ~U[2026-11-01 09:00:00Z]
    Repo.update_all(from(i in Issue, where: i.id == ^issue_id), set: [completed_at: first_write])

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 42, "elsewhere", "main"))
    assert %Issue{state: :done, completed_at: ^first_write} = Repo.get!(Issue, issue_id)
    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
  end

  test "GitHub's delivery after Rail's own Merge changes nothing", %{
    project: project,
    issue: %{id: issue_id},
    task: task,
    closed: closed
  } do
    {:ok, _task} = Pipeline.update_task(task, %{stage: :merged, pr_number: 43})
    expect(Pipeline, :handle_issue_finished, 1, fn %Issue{id: ^issue_id, state: :done} -> :ok end)

    assert :ok = perform_job(AdvanceTrackerState, %{issue_id: issue_id})
    assert %Issue{state: :done, completed_at: %DateTime{} = completed_at} = Repo.get!(Issue, issue_id)

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 43, "elsewhere", "main"))
    assert %Issue{state: :done, completed_at: ^completed_at} = Repo.get!(Issue, issue_id)
    assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue_id})
  end

  test "a split child's merge moves its parent's split on", %{
    project: project,
    issue: parent_issue,
    task: task,
    closed: closed
  } do
    Repo.delete!(task)
    {:ok, %Task{id: parent_task_id}} = Pipeline.create_task(parent_issue, :split)

    {:ok, %Issue{id: child_id} = child} =
      Issues.create_issue(system_scope(), project, %{title: "A part", parent: parent_issue})

    project
    |> build_task(child, %{stage: :finalize, split_position: 1, pr_number: 44})
    |> Ecto.Changeset.put_change(:parent_task_id, parent_task_id)
    |> Repo.insert!()

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 44, "elsewhere", "main"))
    assert %Issue{state: :done} = Repo.get!(Issue, child_id)
    assert_enqueued(worker: AdvanceSplit, args: %{parent_task_id: parent_task_id})
  end

  test "the issue's own branch or pull request, or its task's branch, matches only that issue", %{
    project: project,
    issue: %{id: tasked_id},
    task: %Task{worktree_name: worktree_name},
    closed: closed
  } do
    {:ok, %Issue{id: branched_id} = branched} = Issues.create_issue(system_scope(), project, %{title: "Branched"})
    Repo.update!(Ecto.Changeset.change(branched, branch_name: "someone/outside-rail"))
    {:ok, %Issue{id: linked_id} = linked} = Issues.create_issue(system_scope(), project, %{title: "Linked"})
    Repo.update!(Issue.pull_request_changeset(linked, %{pr_number: 77}))

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 77, "unrelated", "main"))
    assert %Issue{state: :done} = Repo.get!(Issue, linked_id)
    refute match?(%Issue{state: :done}, Repo.get!(Issue, branched_id))
    refute match?(%Issue{state: :done}, Repo.get!(Issue, tasked_id))

    assert :ok =
             Issues.handle_github_webhook(project, "pull_request", closed.(true, 78, "someone/outside-rail", "main"))

    assert %Issue{state: :done} = Repo.get!(Issue, branched_id)
    refute match?(%Issue{state: :done}, Repo.get!(Issue, tasked_id))

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 79, worktree_name, "main"))
    assert %Issue{state: :done} = Repo.get!(Issue, tasked_id)
  end

  test "a pull request closed unmerged, or merged into another base, leaves its issue as it was", %{
    project: project,
    issue: %{id: issue_id, state: state},
    task: task,
    closed: closed
  } do
    {:ok, _task} = Pipeline.update_task(task, %{pr_number: 45})

    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(false, 45, "elsewhere", "main"))
    assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 45, "elsewhere", "release"))

    assert %Issue{state: ^state, completed_at: nil} = Repo.get!(Issue, issue_id)
    refute_enqueued(worker: IssueFinished)
  end

  test "a Canceled issue stays so when its pull request merges", %{project: project, closed: closed} do
    for state <- [:canceled] do
      {:ok, %Issue{id: issue_id} = issue} = Issues.create_issue(system_scope(), project, %{title: "Finished"})
      {:ok, _task} = Pipeline.create_task(issue, :plan)
      Repo.update!(Issue.pull_request_changeset(issue, %{pr_number: 46}))
      status = %{id: Atom.to_string(state), name: Issue.state_label(state), state: state}
      {:ok, _finished} = Issues.set_issue_status(system_scope(), issue, status)

      assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 46, "elsewhere", "main"))
      assert %Issue{state: ^state, completed_at: nil} = Repo.get!(Issue, issue_id)
    end
  end

  test "an issue or comment event, or any other, is ignored", %{project: project, issue: %{id: issue_id, state: state}} do
    assert :ok = Issues.handle_github_webhook(project, "star", %{"action" => "created"})
    assert :ok = Issues.handle_github_webhook(project, "issues", %{"action" => "closed", "issue" => %{"number" => 1}})
    assert :ok = Issues.handle_github_webhook(project, "issue_comment", %{"action" => "created", "comment" => %{}})

    assert %Issue{state: ^state} = Repo.get!(Issue, issue_id)
    refute_enqueued(worker: SyncIssue)
  end
end
