defmodule Rail.Issues do
  @moduledoc """
  Context boundary for Linear-backed issues.

  Local edits write the issue and `Rail.Issues.Workers.SyncIssue` pushes them to
  Linear. Writes reach Linear as the workspace, except a comment, which goes out
  as the scope's user so it carries their name.
  """

  alias Rail.Issues.Actions

  defdelegate list_issues(opts \\ []), to: Actions.ListIssues
  defdelegate get_issue(id), to: Actions.GetIssue
  defdelegate create_issue(project, attrs), to: Actions.CreateIssue
  defdelegate update_issue(issue, attrs), to: Actions.UpdateIssue

  defdelegate sync_issues(project), to: Actions.SyncIssues
  defdelegate handle_linear_webhook(workspace, payload), to: Actions.HandleLinearWebhook
  defdelegate upload_asset(target, filename, content_type, data_binary), to: Actions.UploadAsset
  defdelegate comment(scope, issue, body), to: Actions.Comment
end
