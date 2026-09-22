defmodule RailWeb.Helpers do
  @moduledoc """
  The formatting every template reaches for, in one import.

  `RailWeb.html_helpers/0` imports this, so a LiveView, LiveComponent or function
  component can call any of it without an alias.
  """

  alias RailWeb.Utils

  defdelegate browser_driving(run, task), to: Utils.BrowserDriving
  defdelegate format_age(seconds), to: Utils.FormatAge
  defdelegate format_duration(seconds), to: Utils.FormatDuration
  defdelegate format_run_status(status), to: Utils.FormatRunStatus
  defdelegate render_markdown(content, assets_base \\ nil), to: Utils.RenderMarkdown
  defdelegate role_status_label(role, run, task), to: Utils.RoleStatusLabel
  defdelegate run_state_style(run), to: Utils.RunStateStyle
  defdelegate stage_label(task, run), to: Utils.StageLabel
end
