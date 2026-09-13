defmodule RailWeb.CoreComponents do
  @moduledoc false
  use RailWeb, :html

  defdelegate button(assigns), to: RailWeb.Components.Button
  defdelegate settings_nav(assigns), to: RailWeb.Components.SettingsNav
  defdelegate icon(assigns), to: RailWeb.Components.Icon
  defdelegate project_badge(assigns), to: RailWeb.Components.ProjectBadge
  defdelegate dispatch_banner(assigns), to: RailWeb.Components.DispatchBanner
  defdelegate empty_state(assigns), to: RailWeb.Components.EmptyState
  defdelegate question_card(assigns), to: RailWeb.Components.QuestionCard
  defdelegate with_agent_section(assigns), to: RailWeb.Components.WithAgentSection
  defdelegate role_roster(assigns), to: RailWeb.Components.RoleRoster
  defdelegate issue_card(assigns), to: RailWeb.Components.IssueCard
  defdelegate issue_editor_modal(assigns), to: RailWeb.Components.IssueEditorModal
  defdelegate markdown(assigns), to: RailWeb.Components.Markdown
  defdelegate answer_field(assigns), to: RailWeb.Components.AnswerField
end
