defmodule RailWeb.Components.SettingsNavTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Scope
  alias RailWeb.Components.SettingsNav

  test "renders only the connected accounts and workflows tabs for non-admin user" do
    scope = Scope.for_user(%{admin: false})

    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: scope,
        active_tab: :connected_accounts
      )

    assert html =~ "Connected Accounts"
    assert html =~ "tab-workflows"
    refute html =~ "tab-projects"
    refute html =~ "tab-users"
  end

  test "renders all tabs for admin user with active tab highlighted" do
    scope = Scope.for_user(%{admin: true})

    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: scope,
        active_tab: :projects
      )

    assert html =~ "Connected Accounts"
    assert html =~ "tab-projects"
    assert html =~ "tab-workflows"
    assert html =~ "border-indigo-500 text-indigo-600 font-semibold"
  end
end
