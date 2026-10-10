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
    refute html =~ "tab-hosts"
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
    assert html =~ "border-indigo-500 text-indigo-600 font-semibold"
  end

  test "gives an admin the Hosts tab, after Roles, with the gap narrowed so all nine fit" do
    html =
      render_component(&SettingsNav.settings_nav/1, current_scope: Scope.for_user(%{admin: true}), active_tab: :hosts)

    tabs =
      html |> LazyHTML.from_fragment() |> LazyHTML.query("#settings-tabs a") |> Enum.map(&LazyHTML.attribute(&1, "id"))

    assert [["tab-roles"], ["tab-hosts"]] = Enum.take(tabs, -2)
    assert length(tabs) == 9
    assert html =~ ~s(class="-mb-px flex space-x-6 overflow-x-auto")
  end
end
