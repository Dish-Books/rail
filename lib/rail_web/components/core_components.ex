defmodule RailWeb.CoreComponents do
  @moduledoc false
  use RailWeb, :html

  defdelegate settings_nav(assigns), to: RailWeb.Components.SettingsNav
  defdelegate icon(assigns), to: RailWeb.Components.Icon
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
  defdelegate stage_stepper(assigns), to: RailWeb.Components.StageStepper
  defdelegate stage_outcome(assigns), to: RailWeb.Components.StageOutcome
  defdelegate task_actions(assigns), to: RailWeb.Components.TaskActions
  defdelegate task_action_modals(assigns), to: RailWeb.Components.TaskActionModals
  defdelegate markdown(assigns), to: RailWeb.Components.Markdown
  defdelegate answer_field(assigns), to: RailWeb.Components.AnswerField
  defdelegate conversation_tab(assigns), to: RailWeb.Components.ConversationTab
  defdelegate diff_pane(assigns), to: RailWeb.Components.DiffPane
  defdelegate diff_stat(assigns), to: RailWeb.Components.DiffStat
  defdelegate demo_panel(assigns), to: RailWeb.Components.DemoPanel
  defdelegate no_demo_banner(assigns), to: RailWeb.Components.NoDemoBanner
  defdelegate demo_player_modal(assigns), to: RailWeb.Components.DemoPlayerModal
  defdelegate design_panel(assigns), to: RailWeb.Components.DesignPanel
end
