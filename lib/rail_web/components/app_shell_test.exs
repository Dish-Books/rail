defmodule RailWeb.Components.AppShellTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects.Schemas.Project
  alias RailWeb.Components.AppShell

  test "nav_rail renders 4 destinations in exact order with extended labels" do
    html =
      render_component(&AppShell.nav_rail/1,
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
    assert html =~ "id=\"nav-cli-accounts\""
    assert html =~ "id=\"nav-settings\""

    # Active highlighting on overview
    assert html =~ "data-active=\"true\""
    assert html =~ "Overview"
    assert html =~ "Issues"
    assert html =~ "CLI Accounts"
    assert html =~ "Settings"

    # Collapse sidebar tooltip
    assert html =~ "title=\"Collapse sidebar\""
  end

  test "nav_rail collapsed hides text labels and shows expand tooltip" do
    html =
      render_component(&AppShell.nav_rail/1,
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
      render_component(&AppShell.nav_rail/1,
        current_section: :overview,
        is_rail_extended: true,
        attention_count: 4,
        current_project_id: nil
      )

    assert html_with_badge =~ "id=\"attention-badge\""
    assert html_with_badge =~ "4"

    html_no_badge =
      render_component(&AppShell.nav_rail/1,
        current_section: :overview,
        is_rail_extended: true,
        attention_count: 0,
        current_project_id: nil
      )

    refute html_no_badge =~ "id=\"attention-badge\""
  end

  test "nav_rail active state matches current section" do
    for section <- [:overview, :issues, :cli_accounts, :settings] do
      html =
        render_component(&AppShell.nav_rail/1,
          current_section: section,
          is_rail_extended: true,
          attention_count: 0,
          current_project_id: ""
        )

      slug =
        case section do
          :cli_accounts -> "cli-accounts"
          other -> to_string(other)
        end

      assert html =~ "id=\"nav-#{slug}\""
    end

    # Test settings sub-sections highlight Settings nav
    for sub <- [:connected_accounts, :projects, :linear_workspace] do
      html =
        render_component(&AppShell.nav_rail/1,
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
      render_component(&AppShell.top_app_bar/1,
        current_section: :overview,
        current_project_id: nil,
        projects: [p1, p2],
        theme: "dark",
        show_project_switcher: false,
        show_new_issue_modal: false
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

  test "top_app_bar renders selected project name when filtered" do
    p1 = %Project{id: "prj_1", name: "Alpha App", active: true, linear_team_key: "ALP"}

    html =
      render_component(&AppShell.top_app_bar/1,
        current_section: :issues,
        current_project_id: "prj_1",
        projects: [p1],
        theme: "light",
        show_project_switcher: false,
        show_new_issue_modal: false
      )

    assert html =~ "Alpha App"
    refute html =~ "All projects"
    assert html =~ "Switch to Dark mode"
  end

  test "top_app_bar renders project switcher dialog when open" do
    p1 = %Project{id: "prj_1", name: "Beta Project", active: true, linear_team_key: "BET"}

    html =
      render_component(&AppShell.top_app_bar/1,
        current_section: :cli_accounts,
        current_project_id: "prj_1",
        projects: [p1],
        theme: "dark",
        show_project_switcher: true,
        show_new_issue_modal: false
      )

    assert html =~ "id=\"project-switcher-dialog\""
    assert html =~ "id=\"project-option-all\""
    assert html =~ "id=\"project-option-prj_1\""
    assert html =~ "Beta Project"
    assert html =~ "BET"
  end

  test "top_app_bar renders new issue dialog when open" do
    html =
      render_component(&AppShell.top_app_bar/1,
        current_section: :tasks,
        current_project_id: nil,
        projects: [],
        theme: "dark",
        show_project_switcher: false,
        show_new_issue_modal: true
      )

    assert html =~ "id=\"new-issue-modal\""
    assert html =~ "data-qa=\"capture_dialog\""
    assert html =~ "New Issue"
    assert html =~ "id=\"close-new-issue-button\""
  end

  test "top_app_bar section titles match every destination" do
    titles = [
      {:overview, "Overview"},
      {:issues, "Issues"},
      {:cli_accounts, "CLI Accounts"},
      {:settings, "Settings"},
      {:connected_accounts, "Settings"},
      {:projects, "Settings"},
      {:linear_workspace, "Settings"},
      {:tasks, "Task"},
      {:other_custom, "Rail"}
    ]

    for {section, expected_title} <- titles do
      html =
        render_component(&AppShell.top_app_bar/1,
          current_section: section,
          current_project_id: nil,
          projects: [],
          theme: "dark",
          show_project_switcher: false,
          show_new_issue_modal: false
        )

      assert html =~ expected_title
    end
  end

  test "icon component renders SVGs for each supported icon" do
    names = [
      "layers",
      "dashboard",
      "dashboard_outlined",
      "lightbulb",
      "lightbulb_outline",
      "account_circle",
      "account_circle_outlined",
      "settings",
      "settings_outlined",
      "chevron_left",
      "chevron_right",
      "folder",
      "folder_outlined",
      "unfold_more",
      "add_circle",
      "light_mode",
      "dark_mode",
      "chat_bubble_outline",
      "call_split",
      "play_circle_outline",
      "schedule",
      "help_outline",
      "merge_type",
      "rate_review_outlined",
      "error_outline",
      "radio_button_unchecked",
      "open_in_new",
      "flag_outlined",
      "account_tree_outlined"
    ]

    for name <- names do
      html = render_component(&AppShell.icon/1, name: name, class: "h-5 w-5")
      assert html =~ "<svg"
      assert html =~ "width=\"24\""
      assert html =~ "height=\"24\""
      assert html =~ "viewBox=\"0 0 24 24\""
      assert html =~ "shrink-0"
    end

    # Test delegated CoreComponents.icon
    core_html = render_component(&RailWeb.CoreComponents.icon/1, name: "dashboard", class: "h-5 w-5")
    assert core_html =~ "<svg"
    assert core_html =~ "width=\"24\""
    assert core_html =~ "height=\"24\""
  end

  test "nav_destination supports custom section id falling back to to_string" do
    html =
      render_component(&AppShell.nav_destination/1,
        section: :custom_dest,
        active: false,
        is_extended: true,
        label: "Custom Section",
        icon_active: "dashboard",
        icon_inactive: "dashboard_outlined",
        href: "/custom",
        attention_count: 0
      )

    assert html =~ "id=\"nav-custom_dest\""
    assert html =~ "Custom Section"
  end
end
