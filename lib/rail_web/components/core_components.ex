defmodule RailWeb.CoreComponents do
  @moduledoc false
  use RailWeb, :html

  alias RailWeb.Components.AppShell

  defdelegate settings_nav(assigns), to: RailWeb.Components.SettingsNav
  defdelegate nav_rail(assigns), to: AppShell
  defdelegate top_app_bar(assigns), to: AppShell
  defdelegate icon(assigns), to: AppShell
  defdelegate project_badge(assigns), to: RailWeb.Components.ProjectBadge
  defdelegate dispatch_banner(assigns), to: RailWeb.Components.DispatchBanner
  defdelegate empty_state(assigns), to: RailWeb.Components.EmptyState
  defdelegate question_card(assigns), to: RailWeb.Components.QuestionCard
  defdelegate approval_card(assigns), to: RailWeb.Components.ApprovalCard
  defdelegate compact_waiting_strip(assigns), to: RailWeb.Components.CompactWaitingStrip
  defdelegate with_agent_section(assigns), to: RailWeb.Components.WithAgentSection
  defdelegate role_roster(assigns), to: RailWeb.Components.RoleRoster
  defdelegate issue_card(assigns), to: RailWeb.Components.IssueCard
  defdelegate issue_editor_modal(assigns), to: RailWeb.Components.IssueEditorModal
  defdelegate archive_issue_modal(assigns), to: RailWeb.Components.ArchiveIssueModal
  defdelegate capture_issue_modal(assigns), to: RailWeb.Components.CaptureIssueModal
end
