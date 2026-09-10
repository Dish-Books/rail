defmodule RailWeb.CoreComponents do
  @moduledoc false
  use RailWeb, :html

  alias RailWeb.Components.AppShell

  defdelegate settings_nav(assigns), to: RailWeb.Components.SettingsNav
  defdelegate nav_rail(assigns), to: AppShell
  defdelegate top_app_bar(assigns), to: AppShell
  defdelegate icon(assigns), to: AppShell
end
