defmodule Rail.Issues do
  @moduledoc false

  alias Rail.Issues.Actions

  defdelegate sync_issues(scope, project), to: Actions.SyncIssues
  defdelegate capture_issue(scope, project, ask, opts \\ []), to: Actions.CaptureIssue
  defdelegate get_issue(scope, id), to: Actions.GetIssue
  defdelegate get_issue!(scope, id), to: Actions.GetIssue
  defdelegate list_issues(scope), to: Actions.ListIssues
  defdelegate list_issues(scope, project_or_opts), to: Actions.ListIssues
  defdelegate list_issues(scope, project, opts), to: Actions.ListIssues
  defdelegate update_issue(scope, issue, attrs), to: Actions.UpdateIssue
  defdelegate archive_issue(scope, issue), to: Actions.ArchiveIssue
  defdelegate push_ticket(scope, project, identifier, ticket_content, owner_user \\ nil), to: Actions.PushTicket
  defdelegate create_split_issues(scope, project, split_tickets, owner_user \\ nil), to: Actions.CreateSplitIssues
  defdelegate move_state(scope, project, issue, state_type, owner_user \\ nil), to: Actions.MoveState
  defdelegate upload_asset(scope, filename, content_type, data_binary), to: Actions.UploadAsset

  defdelegate upload_asset(scope, target_or_filename, filename_or_content_type, content_type_or_data, data_or_opts),
    to: Actions.UploadAsset

  defdelegate comment(scope, issue, comment_body, owner_user \\ nil), to: Actions.Comment
end
