defmodule Rail.Issues do
  @moduledoc false

  use Rail.PermissionsDecorator

  alias Rail.Issues.Actions

  @decorate can?(resource: :issues, action: :manage)
  defdelegate sync_issues(scope, project), to: Actions.SyncIssues

  @decorate can?(resource: :issues, action: :manage)
  defdelegate capture_issue(scope, project, ask, opts \\ []), to: Actions.CaptureIssue

  @decorate can?(resource: :issues, action: :view)
  defdelegate get_issue(scope, id), to: Actions.GetIssue

  defdelegate get_issue!(scope, id), to: Actions.GetIssue

  @decorate can?(resource: :issues, action: :view)
  defdelegate list_issues(scope), to: Actions.ListIssues

  @decorate can?(resource: :issues, action: :view)
  defdelegate list_issues(scope, project_or_opts), to: Actions.ListIssues

  @decorate can?(resource: :issues, action: :view)
  defdelegate list_issues(scope, project, opts), to: Actions.ListIssues

  @decorate can?(resource: :issues, action: :manage)
  defdelegate update_issue(scope, issue, attrs), to: Actions.UpdateIssue

  @decorate can?(resource: :issues, action: :manage)
  defdelegate archive_issue(scope, issue), to: Actions.ArchiveIssue

  @decorate can?(resource: :issues, action: :manage)
  defdelegate push_ticket(scope, project, identifier, ticket_content, owner_user \\ nil), to: Actions.PushTicket

  @decorate can?(resource: :issues, action: :manage)
  defdelegate create_split_issues(scope, project, split_tickets, owner_user \\ nil), to: Actions.CreateSplitIssues

  @decorate can?(resource: :issues, action: :manage)
  defdelegate move_state(scope, project, issue, state_type, owner_user \\ nil), to: Actions.MoveState

  @decorate can?(resource: :issues, action: :manage)
  defdelegate upload_asset(scope, filename, content_type, data_binary), to: Actions.UploadAsset

  @decorate can?(resource: :issues, action: :manage)
  defdelegate upload_asset(scope, target_or_filename, filename_or_content_type, content_type_or_data, data_or_opts),
    to: Actions.UploadAsset

  @decorate can?(resource: :issues, action: :manage)
  defdelegate comment(scope, issue, comment_body, owner_user \\ nil), to: Actions.Comment
end
