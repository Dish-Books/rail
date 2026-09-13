defmodule Rail.Pipeline.Actions.ReconcileViewedDiffFilesTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.FileDiff
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "Reconcile Diff Workspace",
        external_id: "lin_ws_reconcile_diff",
        token: "lin_api_token_reconcile_diff",
        webhook_secret: "whsec_reconcile_diff"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Reconcile Diff Project 6901",
        github_repo: "org/reconcile-diff-6901",
        github_installation_id: 6901,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_reconcile_diff_6901",
        linear_team_key: "P6901",
        default_branch: "main",
        clone_path: "/tmp/repos/reconcile-diff-6901",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_reconcile_diff_1",
      "identifier" => "RVD-1",
      "title" => "Reconcile Diff Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "Reconcile Diff Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task}
  end

  test "returns unchanged task if all viewed files match parsed files", %{task: task} do
    expected = %{"lib/foo.ex" => "hash1", "lib/bar.ex" => "hash2"}

    {:ok, task} =
      Pipeline.update_task(task, %{
        viewed_diff_files: expected
      })

    files = [
      FileDiff.new(%{status: :modified, digest: "hash1", new_path: "lib/foo.ex"}),
      FileDiff.new(%{status: :modified, digest: "hash2", new_path: "lib/bar.ex"})
    ]

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.reconcile_viewed_diff_files(task, files)
  end

  test "drops viewed entries when file path is missing or digest changed, and updates database", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        viewed_diff_files: %{
          "lib/keep.ex" => "hash_keep",
          "lib/changed.ex" => "old_hash",
          "lib/deleted.ex" => "deleted_hash"
        }
      })

    files = [
      FileDiff.new(%{status: :modified, digest: "hash_keep", new_path: "lib/keep.ex"}),
      FileDiff.new(%{status: :modified, digest: "new_hash", new_path: "lib/changed.ex"})
    ]

    expected = %{"lib/keep.ex" => "hash_keep"}

    assert {:ok, %Task{viewed_diff_files: ^expected}} =
             Pipeline.reconcile_viewed_diff_files(task, files)
  end

  test "handles empty or nil viewed_diff_files gracefully", %{task: task} do
    {:ok, task} =
      Pipeline.update_task(task, %{
        viewed_diff_files: %{}
      })

    files = [FileDiff.new(%{status: :modified, digest: "hash1", new_path: "lib/foo.ex"})]

    assert {:ok, %Task{viewed_diff_files: %{}}} =
             Pipeline.reconcile_viewed_diff_files(task, files)
  end
end
