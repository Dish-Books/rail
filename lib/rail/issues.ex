defmodule Rail.Issues do
  @moduledoc """
  Context boundary for Linear-backed issues.

  Nothing here is scoped to a user. Linear is the system of record and every
  write reaches it as the workspace, except where a caller names the user the
  work belongs to — `move_state/4` and `comment/4` take that user explicitly so
  the comment carries their name.
  """

  alias Rail.Issues.Actions

  defdelegate sync_issues(project), to: Actions.SyncIssues
  defdelegate create_issue(project, attrs), to: Actions.CreateIssue
  defdelegate get_issue(id), to: Actions.GetIssue
  defdelegate get_issue!(id), to: Actions.GetIssue
  defdelegate list_issues(project_or_opts \\ []), to: Actions.ListIssues
  defdelegate list_issues(project, opts), to: Actions.ListIssues
  defdelegate update_issue(issue, attrs), to: Actions.UpdateIssue
  defdelegate archive_issue(issue), to: Actions.ArchiveIssue
  defdelegate move_state(project, issue, state_type, owner_user \\ nil), to: Actions.MoveState
  defdelegate upload_asset(target, filename, content_type, data_binary), to: Actions.UploadAsset
  defdelegate comment(issue, comment_body, owner_user \\ nil), to: Actions.Comment
end
