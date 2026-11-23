defmodule RailWeb.Components.SettingsNavTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Scope
  alias RailWeb.Components.SettingsNav

  test "renders only the connected accounts and workflows tabs for non-admin user" do
    scope = Scope.for_user(%{admin: false, role: :tester})

    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: scope,
        active_tab: :connected_accounts
      )

    assert html =~ "Connected Accounts"
    assert html =~ ~s(id="tab-workflows")
    refute html =~ "tab-projects"
    refute html =~ "tab-backends"
    refute html =~ "tab-users"
    refute html =~ "tab-intercom-workspaces"
  end

  test "renders all tabs for admin user with active tab highlighted" do
    scope = Scope.for_user(%{admin: true, role: :dev})

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

  test "a support person's only tab is Connected Accounts, with no Workflows" do
    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: Scope.for_user(%{admin: false, role: :support}),
        active_tab: :connected_accounts
      )

    assert html =~ ~s(id="tab-connected-accounts")
    refute html =~ "tab-workflows"
  end

  test "admins get an Intercom tab after Slack, highlighted on the Intercom page" do
    html =
      render_component(&SettingsNav.settings_nav/1,
        current_scope: Scope.for_user(%{admin: true}),
        active_tab: :intercom_workspaces
      )

    assert [_before, after_slack] = String.split(html, ~s(id="tab-slack-workspaces"))

    assert after_slack =~
             ~r/href="\/settings\/intercom-workspaces"[^>]*id="tab-intercom-workspaces" class="border-indigo-500/
  end
end
