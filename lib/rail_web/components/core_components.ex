defmodule RailWeb.CoreComponents do
  @moduledoc """
  Every shared function component, in one import.

  `RailWeb.html_helpers/0` imports this, so a LiveView, LiveComponent or function
  component can render any of them without an import of its own. It must not
  `use RailWeb, :html` itself, or it would import itself.
  """

  alias RailWeb.Components

  defdelegate activity_feed(assigns), to: Components.ActivityFeed
  defdelegate answer_field(assigns), to: Components.AnswerField
  defdelegate assignee(assigns), to: Components.IssueIcons
  defdelegate button(assigns), to: Components.Button
  defdelegate diff_hunk(assigns), to: Components.DiffPane
  defdelegate diff_pane(assigns), to: Components.DiffPane
  defdelegate diff_stat(assigns), to: Components.DiffStat
  defdelegate dispatch_banner(assigns), to: Components.DispatchBanner
  defdelegate icon(assigns), to: Components.Icon
  defdelegate input(assigns), to: Components.Input
  defdelegate issue_card(assigns), to: Components.IssueCard
  defdelegate issue_view(assigns), to: Components.IssueView
  defdelegate markdown(assigns), to: Components.Markdown
  defdelegate nav(assigns), to: Components.Nav
  defdelegate overview_stats(assigns), to: Components.OverviewStats
  defdelegate priority_icon(assigns), to: Components.IssueIcons
  defdelegate project_badge(assigns), to: Components.ProjectBadge
  defdelegate role_roster(assigns), to: Components.RoleRoster
  defdelegate settings_nav(assigns), to: Components.SettingsNav
  defdelegate status_icon(assigns), to: Components.IssueIcons
  defdelegate task_layout(assigns), to: Components.TaskLayout
  defdelegate task_tabs(assigns), to: Components.TaskTabs
  defdelegate throughput_chart(assigns), to: Components.ThroughputChart
  defdelegate top_app_bar(assigns), to: Components.Nav
  defdelegate up_next(assigns), to: Components.UpNext
end
