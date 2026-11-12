defmodule Rail.Issues do
  @moduledoc """
  Context boundary for issues, tracked in Linear, GitHub Issues or Rail itself.

  Local edits write the issue and `Rail.Issues.Workers.SyncIssue` pushes them to
  the tracker, through the project's `Rail.Issues.Tracker`. A person's status change
  goes the other way: the tracker hears first and the row follows its answer. Each
  tracker tells Rail about its own changes through a webhook. A Rail-tracked issue is
  edited here in full, and those edits only tell open pages.
  """

  use Rail.PermissionsDecorator

  alias Rail.Issues.Actions

  defdelegate list_issues(opts \\ []), to: Actions.ListIssues
  defdelegate search_issues(project_id, query), to: Actions.SearchIssues
  defdelegate get_cycles(project), to: Actions.GetCycles
  defdelegate get_statuses(scope, project), to: Actions.GetStatuses
  defdelegate get_blockers(issues), to: Actions.GetBlockers
  defdelegate get_cycle_progress(project, cycle), to: Actions.GetCycleProgress
  defdelegate update_cycle(scope, project, cycle_id, attrs), to: Actions.UpdateCycle
  defdelegate set_issue_cycle(scope, issue, cycle_id), to: Actions.SetIssueCycle
  defdelegate close_cycle_day(today), to: Actions.CloseCycleDay
  defdelegate get_issue(id, opts \\ []), to: Actions.GetIssue
  defdelegate create_issue(scope, project, attrs), to: Actions.CreateIssue
  defdelegate update_issue(issue, attrs), to: Actions.UpdateIssue
  defdelegate claim_issue(scope, issue), to: Actions.ClaimIssue
  defdelegate link_pull_request(scope, issue), to: Actions.LinkPullRequest
  defdelegate advance_issue_state(issue), to: Actions.AdvanceIssueState
  defdelegate link_url(issue, url, title), to: Actions.LinkUrl
  defdelegate reset_issue_state(issue, state), to: Actions.ResetIssueState
  defdelegate set_issue_status(scope, issue, status), to: Actions.SetIssueStatus
  defdelegate save_testing_notes(scope, issue, notes), to: Actions.SaveTestingNotes
  defdelegate mark_issue_tested(scope, issue), to: Actions.MarkIssueTested
  defdelegate send_issue_to_triage(scope, issue), to: Actions.SendIssueToTriage
  defdelegate edit_issue(scope, issue, attrs), to: Actions.EditIssue
  defdelegate upload_file(scope, issue, filename, data), to: Actions.UploadFile
  defdelegate block_issue(scope, blocker, blocked), to: Actions.BlockIssue
  defdelegate unblock_issue(scope, blocker, blocked), to: Actions.UnblockIssue

  @decorate can?(resource: :projects, action: :update)
  defdelegate move_to_local_tracker(scope, project), to: Actions.MoveToLocalTracker

  @decorate can?(resource: :projects, action: :update)
  defdelegate list_tracker_moves(scope, projects), to: Actions.ListTrackerMoves

  defdelegate sync_issues(project), to: Actions.SyncIssues
  defdelegate import_issue(project, identifier), to: Actions.ImportIssue
  defdelegate handle_linear_webhook(workspace, payload), to: Actions.HandleLinearWebhook
  defdelegate upload_asset(issue, filename, content_type, data_binary), to: Actions.UploadAsset
  defdelegate get_asset(issue, path), to: Actions.GetAsset
  defdelegate comment(scope, issue, attrs), to: Actions.Comment
  defdelegate set_up_tracker(project), to: Actions.SetUpTracker
  defdelegate handle_github_webhook(project, event, payload), to: Actions.HandleGithubWebhook
end
