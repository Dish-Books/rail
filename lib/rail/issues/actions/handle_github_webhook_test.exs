defmodule Rail.Issues.Actions.HandleGithubWebhookTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Pipeline.Utils.BuildTask

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.AdvanceSplit
  alias Rail.Projects
  alias Rail.Users

  describe "issues" do
    test "an issue opened on GitHub is mirrored, with nothing pushed back", %{github_project: %{id: project_id} = project} do
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      payload =
        github_issue_json(%{"number" => 81, "title" => "From GitHub", "labels" => [%{"name" => "rail:high"}]})

      assert {:ok, %Issue{id: issue_id, identifier: "tgh#81", state: :backlog, priority: :high, project_id: ^project_id}} =
               Issues.handle_github_webhook(project, "issues", %{"action" => "opened", "issue" => payload})

      assert_received {:issue_changed, ^issue_id}
      refute_enqueued(worker: SyncIssue)
    end

    test "a label or a close moves the state, and a finish goes to Learnings once", %{github_project: project} do
      issue =
        github_issue(project, %{number: 82, state: :in_review, external_updated_at: ~U[2026-10-06 10:00:00.000000Z]})

      base = github_issue_json(%{"node_id" => issue.external_id, "number" => 82})
      later = &Map.put(base, "updated_at", "2026-10-06T11:0#{&1}:00Z")

      assert {:ok, %Issue{state: :in_progress}} =
               Issues.handle_github_webhook(project, "issues", %{
                 "action" => "labeled",
                 "issue" => Map.put(later.(1), "labels", [%{"name" => "rail:in-progress"}])
               })

      closed =
        2
        |> later.()
        |> Map.merge(%{"state" => "closed", "state_reason" => "not_planned", "closed_at" => "2026-10-06T11:02:00Z"})

      assert {:ok, %Issue{state: :canceled}} =
               Issues.handle_github_webhook(project, "issues", %{"action" => "closed", "issue" => closed})

      assert {:ok, %Issue{state: :canceled}} =
               Issues.handle_github_webhook(project, "issues", %{
                 "action" => "edited",
                 "issue" => Map.put(closed, "updated_at", "2026-10-06T11:03:00Z")
               })

      assert [_once] = all_enqueued(worker: IssueFinished, args: %{issue_id: issue.id})
    end

    test "a finish tells the pipeline once, so a split moves on", %{github_project: project} do
      %{id: issue_id} = issue = github_issue(project, %{number: 182, state: :in_review})

      closed =
        github_issue_json(%{
          "node_id" => issue.external_id,
          "number" => 182,
          "state" => "closed",
          "state_reason" => "completed",
          "closed_at" => "2026-10-06T11:02:00Z",
          "updated_at" => "2026-10-06T11:02:00Z"
        })

      expect(Pipeline, :handle_issue_finished, 1, fn %Issue{id: ^issue_id, state: :done} -> :ok end)

      assert {:ok, %Issue{state: :done}} =
               Issues.handle_github_webhook(project, "issues", %{"action" => "closed", "issue" => closed})

      assert {:ok, %Issue{state: :done}} =
               Issues.handle_github_webhook(project, "issues", %{"action" => "edited", "issue" => closed})
    end

    test "a delivery older than what Rail holds changes nothing", %{github_project: project} do
      issue = github_issue(project, %{number: 83, title: "Newer", external_updated_at: ~U[2026-10-06 12:00:00.000000Z]})

      stale =
        github_issue_json(%{
          "node_id" => issue.external_id,
          "number" => 83,
          "title" => "Older",
          "updated_at" => "2026-10-06T11:00:00Z"
        })

      assert :ok = Issues.handle_github_webhook(project, "issues", %{"action" => "edited", "issue" => stale})
      assert %Issue{title: "Newer"} = Repo.reload!(issue)
    end

    test "Rail's owner stays unless GitHub names a different Rail user", %{github_project: project} do
      [%{id: kept_id}, %{id: other_id}] =
        Enum.map(["7101", "7102"], fn github_id ->
          {:ok, user} =
            Users.register_oauth_user(%{github_id: github_id, login: "w#{github_id}", email: "w#{github_id}@example.com"})

          user
        end)

      issue = github_issue(project, %{number: 84, owner_user_id: kept_id})
      payload = &github_issue_json(%{"node_id" => issue.external_id, "number" => 84, "assignees" => &1})

      assert {:ok, %Issue{owner_user_id: ^kept_id}} =
               Issues.handle_github_webhook(project, "issues", %{
                 "action" => "assigned",
                 "issue" => payload.([%{"id" => 404}])
               })

      assert {:ok, %Issue{owner_user_id: ^other_id}} =
               Issues.handle_github_webhook(project, "issues", %{
                 "action" => "assigned",
                 "issue" => payload.([%{"id" => 7102}])
               })
    end

    test "an issue deleted or moved to another repository is deleted", %{github_project: project} do
      for action <- ["deleted", "transferred"] do
        issue = github_issue(project)
        payload = %{"action" => action, "issue" => github_issue_json(%{"node_id" => issue.external_id})}

        assert {:ok, %Issue{}} = Issues.handle_github_webhook(project, "issues", payload)
        refute Repo.reload(issue)
        assert :ok = Issues.handle_github_webhook(project, "issues", payload)
      end
    end
  end

  describe "issue_comment" do
    test "a comment is kept on its issue, edited in place and deleted", %{github_project: project} do
      %Issue{id: issue_id} = github_issue(project, %{number: 85})
      comment = github_comment_json(%{"body" => "First"})
      issue_payload = %{"number" => 85}

      assert {:ok, %Comment{issue_id: ^issue_id, body: "First"}} =
               Issues.handle_github_webhook(project, "issue_comment", %{
                 "action" => "created",
                 "issue" => issue_payload,
                 "comment" => comment
               })

      assert {:ok, %Comment{body: "Edited"}} =
               Issues.handle_github_webhook(project, "issue_comment", %{
                 "action" => "edited",
                 "issue" => issue_payload,
                 "comment" => Map.put(comment, "body", "Edited")
               })

      deleted = %{"action" => "deleted", "issue" => issue_payload, "comment" => comment}
      assert {:ok, %Comment{}} = Issues.handle_github_webhook(project, "issue_comment", deleted)
      refute Repo.get_by(Comment, external_id: comment["node_id"])
      assert :ok = Issues.handle_github_webhook(project, "issue_comment", deleted)
    end

    test "a comment on a pull request, or on an issue Rail has not pulled, is left for later", %{github_project: project} do
      comment = github_comment_json()

      assert :ok =
               Issues.handle_github_webhook(project, "issue_comment", %{
                 "action" => "created",
                 "issue" => %{"number" => 86, "pull_request" => %{}},
                 "comment" => comment
               })

      assert :ok =
               Issues.handle_github_webhook(project, "issue_comment", %{
                 "action" => "created",
                 "issue" => %{"number" => 999_999},
                 "comment" => comment
               })

      refute Repo.get_by(Comment, external_id: comment["node_id"])
    end
  end

  describe "pull_request on a Rail-tracked project" do
    setup do
      key = "Prm#{System.unique_integer([:positive])}"

      {:ok, project} =
        Projects.create_project(system_scope(), %{
          name: "Rail-tracked",
          github_repo: "example/#{key}",
          github_installation_id: 1,
          tracker: :local,
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

      assert %Issue{state: :done, state_name: "Done", completed_at: %DateTime{}} = Repo.get!(Issue, issue_id)
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

    test "a Canceled or Duplicate issue stays so when its pull request merges", %{project: project, closed: closed} do
      for state <- [:canceled, :duplicate] do
        {:ok, %Issue{id: issue_id} = issue} = Issues.create_issue(system_scope(), project, %{title: "Finished"})
        {:ok, _task} = Pipeline.create_task(issue, :plan)
        Repo.update!(Issue.pull_request_changeset(issue, %{pr_number: 46}))
        status = %{id: Atom.to_string(state), name: Issue.state_label(state), state: state}
        {:ok, _finished} = Issues.set_issue_status(system_scope(), issue, status)

        assert :ok = Issues.handle_github_webhook(project, "pull_request", closed.(true, 46, "elsewhere", "main"))
        assert %Issue{state: ^state, completed_at: nil} = Repo.get!(Issue, issue_id)
      end
    end
  end

  test "a GitHub-tracked project's merged pull request changes nothing", %{github_project: project} do
    %Issue{id: issue_id} = issue = github_issue(project, %{number: 87, state: :in_review})
    Repo.update!(Issue.pull_request_changeset(issue, %{pr_number: 87}))

    assert :ok =
             Issues.handle_github_webhook(project, "pull_request", %{
               "action" => "closed",
               "pull_request" => %{
                 "merged" => true,
                 "number" => 87,
                 "head" => %{"ref" => "tgh-87"},
                 "base" => %{"ref" => "main"}
               }
             })

    assert %Issue{state: :in_review} = Repo.get!(Issue, issue_id)
  end

  test "any other event is ignored", %{github_project: project} do
    assert :ok = Issues.handle_github_webhook(project, "star", %{"action" => "created"})
  end
end
