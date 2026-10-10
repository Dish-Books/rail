defmodule Rail.Issues.Actions.HandleGithubWebhookTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Learnings.Workers.IssueFinished
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

  test "any other event is ignored", %{github_project: project} do
    assert :ok = Issues.handle_github_webhook(project, "star", %{"action" => "created"})
  end
end
