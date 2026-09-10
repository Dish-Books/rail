defmodule RailWeb.Components.SettingsNavTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Scope
  alias RailWeb.Components.SettingsNav

  test "renders only connected accounts tab for non-admin user" do
    scope = Scope.for_user(%{admin: false})

    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: scope,
        active_tab: :connected_accounts
      )

    assert html =~ "Connected Accounts"
    refute html =~ "tab-projects"
    refute html =~ "tab-linear-workspace"
  end

  test "renders all three tabs for admin user with active tab highlighted" do
    scope = Scope.for_user(%{admin: true})

    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: scope,
        active_tab: :projects
      )

    assert html =~ "Connected Accounts"
    assert html =~ "tab-projects"
    assert html =~ "tab-linear-workspace"
    assert html =~ "border-indigo-500 text-indigo-600 font-semibold"
  end

  test "renders linear workspace tab as active when active_tab is :linear_workspace" do
    scope = Scope.for_user(%{admin: true})

    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: scope,
        active_tab: :linear_workspace
      )

    assert html =~ "Linear Workspace"
    assert html =~ "tab-linear-workspace"
  end
end
