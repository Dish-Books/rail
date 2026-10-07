defmodule Rail.Issues do
  @moduledoc """
  Context boundary for issues, tracked in Linear or GitHub Issues.

  Local edits write the issue and `Rail.Issues.Workers.SyncIssue` pushes them to
  the tracker, through the project's `Rail.Issues.Tracker`. Each tracker tells Rail
  about its own changes through a webhook.
  """

  alias Rail.Issues.Actions

  defdelegate list_issues(opts \\ []), to: Actions.ListIssues
  defdelegate get_issue(id, opts \\ []), to: Actions.GetIssue
  defdelegate create_issue(scope, project, attrs), to: Actions.CreateIssue
  defdelegate update_issue(issue, attrs), to: Actions.UpdateIssue
  defdelegate claim_issue(scope, issue), to: Actions.ClaimIssue
  defdelegate advance_issue_state(issue), to: Actions.AdvanceIssueState

  defdelegate sync_issues(project), to: Actions.SyncIssues
  defdelegate import_issue(project, identifier), to: Actions.ImportIssue
  defdelegate handle_linear_webhook(workspace, payload), to: Actions.HandleLinearWebhook
  defdelegate upload_asset(target, filename, content_type, data_binary), to: Actions.UploadAsset
  defdelegate get_asset(issue, path), to: Actions.GetAsset
  defdelegate comment(scope, issue, attrs), to: Actions.Comment
  defdelegate set_up_tracker(project), to: Actions.SetUpTracker
  defdelegate handle_github_webhook(project, event, payload), to: Actions.HandleGithubWebhook
end
