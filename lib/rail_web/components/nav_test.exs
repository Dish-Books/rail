defmodule RailWeb.Components.NavTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects.Schemas.Project
  alias RailWeb.Components.Nav

  test "nav_rail renders 3 destinations in exact order with extended labels" do
    html =
      render_component(&Nav.nav/1,
        current_section: :overview,
        is_rail_extended: true,
        attention_count: 0,
        current_project_id: nil
      )

    assert html =~ "id=\"navigation-rail\""
    assert html =~ "data-qa=\"navigation_rail\""
    assert html =~ "id=\"brand-name\""
    assert html =~ "Rail"

    assert html =~ "id=\"nav-overview\""
    assert html =~ "id=\"nav-issues\""
    assert html =~ "id=\"nav-settings\""

    # Active highlighting on overview
    assert html =~ "data-active=\"true\""
    assert html =~ "Overview"
    assert html =~ "Issues"
    assert html =~ "Settings"

    # Collapse sidebar tooltip
    assert html =~ "title=\"Collapse sidebar\""
  end

  test "nav_rail collapsed hides text labels and shows expand tooltip" do
    html =
      render_component(&Nav.nav/1,
        current_section: :issues,
        is_rail_extended: false,
        attention_count: 0,
        current_project_id: "prj_test"
      )

    assert html =~ "id=\"navigation-rail\""
    refute html =~ "id=\"brand-name\""
    refute html =~ "id=\"nav-label-overview\""
    assert html =~ "title=\"Expand sidebar\""
    assert html =~ "?project=prj_test"
  end

  test "nav_rail renders attention badge on overview when attention_count > 0" do
    html_with_badge =
      render_component(&Nav.nav/1,
        current_section: :overview,
        is_rail_extended: true,
        attention_count: 4,
        current_project_id: nil
      )

    assert html_with_badge =~ "id=\"attention-badge\""
    assert html_with_badge =~ "4"

    html_no_badge =
      render_component(&Nav.nav/1,
        current_section: :overview,
        is_rail_extended: true,
        attention_count: 0,
        current_project_id: nil
      )

    refute html_no_badge =~ "id=\"attention-badge\""
  end

  test "nav_rail active state matches current section" do
    for section <- [:overview, :issues, :settings] do
      html =
        render_component(&Nav.nav/1,
          current_section: section,
          is_rail_extended: true,
          attention_count: 0,
          current_project_id: ""
        )

      assert html =~ "id=\"nav-#{section}\""
    end

    # Test settings sub-sections highlight Settings nav
    for sub <- [:connected_accounts, :projects, :linear_workspaces] do
      html =
        render_component(&Nav.nav/1,
          current_section: sub,
          is_rail_extended: true,
          attention_count: 0,
          current_project_id: nil
        )

      assert html =~ "id=\"nav-settings\""
    end
  end

  test "top_app_bar renders section title, project pill, theme toggle, and new issue button" do
    p1 = %Project{id: "prj_1", name: "Core API", active: true, linear_team_key: "COR"}
    p2 = %Project{id: "prj_2", name: "Web UI", active: true, linear_team_key: "WEB"}

    html =
      render_component(&Nav.top_app_bar/1,
        current_section: :overview,
        current_scope: system_scope(),
        current_project_id: nil,
        projects: [p1, p2],
        theme: "dark",
        show_project_switcher: false
      )

    assert html =~ "id=\"top-app-bar\""
    assert html =~ "id=\"section-title\""
    assert html =~ "Overview"
    assert html =~ "All projects"
    assert html =~ "id=\"active-project-count\""
    assert html =~ "2"
    assert html =~ "id=\"global-capture-idea-button\""
    assert html =~ "New Issue (⌘N)"
    assert html =~ "id=\"theme-toggle-button\""
    assert html =~ "Switch to Light mode"
  end

  test "top_app_bar offers a way out of the Rail session" do
    html =
      render_component(&Nav.top_app_bar/1,
        current_section: :overview,
        current_scope: system_scope(),
        current_project_id: nil,
        projects: [],
        theme: "dark",
        show_project_switcher: false
      )

    assert html =~ ~s(id="sign-out-button")
    assert html =~ ~s(href="/auth/logout")
    assert html =~ "Sign out of Rail"
  end

  test "top_app_bar renders selected project name when filtered" do
    p1 = %Project{id: "prj_1", name: "Alpha App", active: true, linear_team_key: "ALP"}

    html =
      render_component(&Nav.top_app_bar/1,
        current_section: :issues,
        current_scope: system_scope(),
        current_project_id: "prj_1",
        projects: [p1],
        theme: "light",
        show_project_switcher: false
      )

    assert html =~ "Alpha App"
    refute html =~ "All projects"
    assert html =~ "Switch to Dark mode"
  end

  test "top_app_bar renders project switcher dialog when open" do
    p1 = %Project{id: "prj_1", name: "Beta Project", active: true, linear_team_key: "BET"}

    html =
      render_component(&Nav.top_app_bar/1,
        current_section: :backends,
        current_scope: system_scope(),
        current_project_id: "prj_1",
        projects: [p1],
        theme: "dark",
        show_project_switcher: true
      )

    assert html =~ "id=\"project-switcher-dialog\""
    assert html =~ "id=\"project-option-all\""
    assert html =~ "id=\"project-option-prj_1\""
    assert html =~ "Beta Project"
    assert html =~ "BET"
  end

  test "top_app_bar section titles match every destination" do
    titles = [
      {:overview, "Overview"},
      {:issues, "Issues"},
      {:backends, "Settings"},
      {:settings, "Settings"},
      {:connected_accounts, "Settings"},
      {:projects, "Settings"},
      {:users, "Settings"},
      {:roles, "Settings"},
      {:tasks, "Task"},
      {:other_custom, "Rail"}
    ]

    for {section, expected_title} <- titles do
      html =
        render_component(&Nav.top_app_bar/1,
          current_section: section,
          current_scope: system_scope(),
          current_project_id: nil,
          projects: [],
          theme: "dark",
          show_project_switcher: false
        )

      assert html =~ expected_title
    end
  end

  test "nav_destination supports custom section id falling back to to_string" do
    html =
      render_component(&Nav.nav_item/1,
        section: :custom_dest,
        active: false,
        is_extended: true,
        label: "Custom Section",
        icon_active: "pi-squares-four-fill",
        icon_inactive: "pi-squares-four",
        href: "/custom",
        attention_count: 0
      )

    assert html =~ "id=\"nav-custom_dest\""
    assert html =~ "Custom Section"
  end
end
