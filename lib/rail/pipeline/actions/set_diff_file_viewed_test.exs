defmodule Rail.Pipeline.Actions.SetDiffFileViewedTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Set Diff Viewed Workspace",
        external_id: "lin_ws_set_diff_viewed",
        token: "lin_api_token_set_diff_viewed",
        webhook_secret: "whsec_set_diff_viewed"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Set Diff Viewed Project 7001",
        github_repo: "org/set-diff-viewed-7001",
        github_installation_id: 7001,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_set_diff_viewed_7001",
        linear_team_key: "P7001",
        clone_path: "/tmp/repos/set-diff-viewed-7001",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_set_diff_viewed_1",
      "identifier" => "SDV-1",
      "title" => "Set Diff Viewed Issue"
    })

    {:ok, issue} = Issues.capture_issue(scope, project, "Set Diff Viewed Issue")

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "sets viewed status and digest for a file", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(system_scope(), task, %{
        viewed_diff_files: %{}
      })

    expected = %{"lib/example.ex" => "sha256_abc"}

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.set_diff_file_viewed(task, "lib/example.ex", "sha256_abc", true)
  end

  test "supports scope as first argument and unsets viewed status when viewed is false", %{task: task} do
    scope = Rail.Scope.for_system()

    {:ok, task} =
      Pipeline.update_task(system_scope(), task, %{
        viewed_diff_files: %{"lib/example.ex" => "sha256_abc", "lib/other.ex" => "sha256_def"}
      })

    expected = %{"lib/other.ex" => "sha256_def"}

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.set_diff_file_viewed(scope, task, "lib/example.ex", "sha256_abc", false)
  end
end
