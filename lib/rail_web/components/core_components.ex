defmodule RailWeb.CoreComponents do
  @moduledoc """
  Every shared function component, in one import.

  `RailWeb.html_helpers/0` imports this, so a LiveView, LiveComponent or function
  component can render any of them without an import of its own. It must not
  `use RailWeb, :html` itself, or it would import itself.
  """

  alias RailWeb.Components

  defdelegate answer_field(assigns), to: Components.AnswerField
  defdelegate assignee(assigns), to: Components.IssueIcons
  defdelegate button(assigns), to: Components.Button
  defdelegate dispatch_banner(assigns), to: Components.DispatchBanner
  defdelegate empty_state(assigns), to: Components.EmptyState
  defdelegate icon(assigns), to: Components.Icon
  defdelegate issue_card(assigns), to: Components.IssueCard
  defdelegate markdown(assigns), to: Components.Markdown
  defdelegate nav(assigns), to: Components.Nav
  defdelegate priority_icon(assigns), to: Components.IssueIcons
  defdelegate project_badge(assigns), to: Components.ProjectBadge
  defdelegate question_card(assigns), to: Components.QuestionCard
  defdelegate role_roster(assigns), to: Components.RoleRoster
  defdelegate settings_nav(assigns), to: Components.SettingsNav
  defdelegate status_icon(assigns), to: Components.IssueIcons
  defdelegate task_layout(assigns), to: Components.TaskLayout
  defdelegate top_app_bar(assigns), to: Components.Nav
  defdelegate with_agent_section(assigns), to: Components.WithAgentSection
end
