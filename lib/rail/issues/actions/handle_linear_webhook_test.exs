defmodule Rail.Issues.Actions.HandleLinearWebhookTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, %Project{linear_workspace_id: workspace_id} = project} =
      Projects.create_project(system_scope(), %{
        name: "Handle Webhook Project",
        github_repo: "org/handle-webhook",
        github_installation_id: 12_950,
        linear_team_key: "HWH",
        default_branch: "main",
        clone_path: "/tmp/repos/handle-webhook",
        linear_workspace: %{
          name: "Handle Webhook Workspace",
          external_id: "lin_ws_handle_webhook",
          token: "lin_api_token_handle_webhook",
          webhook_secret: "whsec_handle_webhook"
        }
      })

    {:ok, workspace} = Projects.get_linear_workspace(id: workspace_id)

    %{project: project, workspace: workspace}
  end

  test "an issue create mirrors the issue onto the workspace's project", %{
    project: %Project{id: project_id},
    workspace: workspace
  } do
    assert {:ok, %Issue{id: "iss_" <> _id}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "create",
               "data" => %{
                 "id" => "lin_wh_1",
                 "teamId" => "lin_team_id",
                 "identifier" => "HWH-1",
                 "title" => "Webhook Issue",
                 "description" => "Created via webhook",
                 "priority" => 2,
                 "state" => %{"id" => "st_started", "name" => "In Progress", "type" => "started"},
                 "branchName" => "hwh-1-webhook",
                 "url" => "https://linear.app/issue/HWH-1"
               }
             })

    assert %Issue{
             project_id: ^project_id,
             identifier: "HWH-1",
             title: "Webhook Issue",
             description: "Created via webhook",
             priority: :high,
             state: :in_progress,
             state_name: "In Progress",
             branch_name: "hwh-1-webhook",
             url: "https://linear.app/issue/HWH-1"
           } = Repo.get_by(Issue, external_id: "lin_wh_1")
  end

  test "an issue update changes the existing row and pushes nothing back to Linear", %{
    project: project,
    workspace: workspace
  } do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_2",
        identifier: "HWH-2",
        title: "Initial Title",
        state: :triage
      })
      |> Repo.insert!()

    assert {:ok, %Issue{id: ^issue_id, title: "Updated Title", state: :done}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Issue",
               "action" => "update",
               "data" => %{
                 "id" => "lin_wh_2",
                 "teamId" => "lin_team_id",
                 "identifier" => "HWH-2",
                 "title" => "Updated Title",
                 "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"}
               }
             })

    refute_enqueued(worker: SyncIssue)
  end

  test "an issue remove deletes the row, and one Rail never had is fine", %{project: project, workspace: workspace} do
    %Issue{}
    |> Issue.linear_changeset(%{
      project_id: project.id,
      external_id: "lin_wh_3",
      identifier: "HWH-3",
      title: "Doomed",
      state: :triage
    })
    |> Repo.insert!()

    remove = %{"type" => "Issue", "action" => "remove", "data" => %{"id" => "lin_wh_3"}}

    assert {:ok, %Issue{}} = Issues.handle_linear_webhook(workspace, remove)
    assert Repo.get_by(Issue, external_id: "lin_wh_3") == nil
    assert :ok = Issues.handle_linear_webhook(workspace, remove)
  end

  test "an issue goes to the project on its team when the workspace has several", %{project: %Project{id: project_id}} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_other"}]}}})
    end)

    {:ok, %Project{id: other_project_id}} =
      Projects.create_project(system_scope(), %{
        name: "Other Team Project",
        github_repo: "org/other-team",
        github_installation_id: 12_951,
        linear_team_key: "OTH",
        default_branch: "main",
        clone_path: "/tmp/repos/other-team",
        linear_workspace: %{
          name: "Handle Webhook Workspace",
          external_id: "lin_ws_handle_webhook",
          token: "lin_api_token_handle_webhook",
          webhook_secret: "whsec_handle_webhook"
        }
      })

    {:ok, workspace} = Projects.get_linear_workspace(external_id: "lin_ws_handle_webhook")

    issue = fn id, team_id ->
      %{
        "type" => "Issue",
        "action" => "create",
        "data" => %{"id" => id, "identifier" => id, "title" => id, "teamId" => team_id}
      }
    end

    assert {:ok, %Issue{project_id: ^project_id}} =
             Issues.handle_linear_webhook(workspace, issue.("HWH-5", "lin_team_id"))

    assert {:ok, %Issue{project_id: ^other_project_id}} =
             Issues.handle_linear_webhook(workspace, issue.("OTH-1", "lin_team_other"))

    assert :ok = Issues.handle_linear_webhook(workspace, issue.("NOP-1", "lin_team_unclaimed"))
    assert Repo.get_by(Issue, external_id: "NOP-1") == nil
  end

  test "an issue on a team no project is on and events that are not issues change nothing", %{workspace: workspace} do
    event = %{
      "type" => "Issue",
      "action" => "create",
      "data" => %{"id" => "lin_wh_4", "identifier" => "HWH-4", "title" => "Orphan", "teamId" => "lin_team_unclaimed"}
    }

    assert :ok = Issues.handle_linear_webhook(workspace, event)
    assert :ok = Issues.handle_linear_webhook(workspace, %{"type" => "Project", "action" => "create", "data" => %{}})
    assert Repo.get_by(Issue, external_id: "lin_wh_4") == nil
  end

  test "comment creates, replies, updates and removes mirror onto the issue", %{project: project, workspace: workspace} do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_wh_5",
        identifier: "HWH-5",
        title: "Discussed",
        state: :triage
      })
      |> Repo.insert!()

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok, %Comment{id: parent_id, issue_id: ^issue_id, parent_id: nil, body: "Open question"}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Comment",
               "action" => "create",
               "data" => %{
                 "id" => "lin_wh_com_1",
                 "body" => "Open question",
                 "issueId" => "lin_wh_5",
                 "userId" => "lin_usr_nobody",
                 "createdAt" => "2026-09-09T10:00:00.000Z"
               }
             })

    assert_receive {:issue_comments_changed, ^issue_id}

    reply = %{
      "type" => "Comment",
      "action" => "create",
      "data" => %{"id" => "lin_wh_com_2", "body" => "yes", "issueId" => "lin_wh_5", "parentId" => "lin_wh_com_1"}
    }

    assert {:ok, %Comment{parent_id: ^parent_id}} = Issues.handle_linear_webhook(workspace, reply)

    assert {:ok, %Comment{id: ^parent_id, body: "Edited question"}} =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Comment",
               "action" => "update",
               "data" => %{"id" => "lin_wh_com_1", "body" => "Edited question", "issueId" => "lin_wh_5"}
             })

    remove = %{"type" => "Comment", "action" => "remove", "data" => %{"id" => "lin_wh_com_1"}}

    assert {:ok, %Comment{}} = Issues.handle_linear_webhook(workspace, remove)
    # The thread's replies go with it.
    assert [] = Repo.all(Comment)
    assert :ok = Issues.handle_linear_webhook(workspace, remove)
  end

  test "a comment on an issue or thread Rail has not synced yet is left for the next sync", %{workspace: workspace} do
    assert :ok =
             Issues.handle_linear_webhook(workspace, %{
               "type" => "Comment",
               "action" => "create",
               "data" => %{"id" => "lin_wh_com_3", "body" => "Early", "issueId" => "lin_unsynced"}
             })

    assert [] = Repo.all(Comment)
  end
end
