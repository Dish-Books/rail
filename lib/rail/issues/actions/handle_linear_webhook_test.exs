defmodule Rail.Issues.Actions.HandleLinearWebhookTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  setup do
    {:ok, %Project{linear_workspace: workspace} = project} =
      Projects.create_project(system_scope(), %{
        name: "Handle Webhook Project",
        github_repo: "org/handle-webhook",
        github_installation_id: 12_950,
        linear_team_id: "team_handle_webhook",
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

  test "a workspace without a project and events that are not issues change nothing", %{workspace: workspace} do
    event = %{
      "type" => "Issue",
      "action" => "create",
      "data" => %{"id" => "lin_wh_4", "identifier" => "HWH-4", "title" => "Orphan"}
    }

    assert :ok = Issues.handle_linear_webhook(%{workspace | project_id: nil}, event)
    assert :ok = Issues.handle_linear_webhook(workspace, %{"type" => "Comment", "action" => "create", "data" => %{}})
    assert Repo.get_by(Issue, external_id: "lin_wh_4") == nil
  end
end
