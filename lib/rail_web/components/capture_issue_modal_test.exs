defmodule RailWeb.Components.CaptureIssueModalTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Projects.Schemas.Project
  alias RailWeb.Components.CaptureIssueModal

  test "capture_issue_modal renders dialog, modal containers, and title when visible" do
    html =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [],
        current_project_id: nil,
        capture_ask: "",
        capture_project_id: nil,
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: false
      )

    assert html =~ "id=\"capture-idea-dialog\""
    assert html =~ "data-qa=\"capture_idea_dialog\""
    assert html =~ "data-qa=\"capture_dialog\""
    assert html =~ "id=\"new-issue-modal\""
    assert html =~ "id=\"capture-modal-title\""
    assert html =~ "data-qa=\"capture_modal_title\""
    assert html =~ "New Issue"
    assert html =~ "id=\"close-new-issue-button\""
    assert html =~ "data-qa=\"close_new_issue_button\""
    assert html =~ "id=\"capture-issue-form\""
  end

  test "capture_issue_modal renders single multiline ask input and strictly excludes separate title or description fields" do
    html =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [],
        current_project_id: nil,
        capture_ask: "Fix the navigation crash",
        capture_project_id: nil,
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: false
      )

    assert html =~ "id=\"capture-idea-input\""
    assert html =~ "name=\"ask\""
    assert html =~ "data-qa=\"capture_idea_input\""
    assert html =~ "placeholder=\"What's the idea?\""
    assert html =~ "Fix the navigation crash"

    refute html =~ "data-qa=\"capture_title_input\""
    refute html =~ "data-qa=\"capture_description_input\""
    refute html =~ "id=\"capture-title-input\""
    refute html =~ "id=\"capture-description-input\""
  end

  test "capture_issue_modal renders project dropdown, priority options, and actions" do
    project1 = %Project{id: "prj_1", name: "Alpha App", linear_team_key: "ALP", active: true}
    project2 = %Project{id: "prj_2", name: "Beta Core", linear_team_key: "BET", active: true}

    html =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [project1, project2],
        current_project_id: "prj_1",
        capture_ask: "Work on backend",
        capture_project_id: "prj_2",
        capture_priority: :urgent,
        capture_error: nil,
        capture_submitting: false
      )

    assert html =~ "id=\"capture-project-dropdown\""
    assert html =~ "data-qa=\"capture_project_dropdown\""
    assert html =~ "Alpha App (ALP)"
    assert html =~ "Beta Core (BET)"
    assert html =~ "value=\"prj_2\" selected"

    assert html =~ "id=\"capture-priority-dropdown\""
    assert html =~ "data-qa=\"capture_priority_dropdown\""
    assert html =~ "value=\"urgent\" selected"
    assert html =~ "Urgent"
    assert html =~ "High"
    assert html =~ "Medium"
    assert html =~ "Low"

    assert html =~ "id=\"capture-cancel-button\""
    assert html =~ "data-qa=\"capture_cancel_button\""
    assert html =~ "id=\"capture-submit-button\""
    assert html =~ "data-qa=\"capture_submit_button\""
    assert html =~ "Add to Backlog (⌘Enter)"
    refute html =~ "disabled"
  end

  test "capture_issue_modal disables submit button when ask is empty or whitespace" do
    project = %Project{id: "prj_1", name: "Alpha App", linear_team_key: "ALP", active: true}

    html_empty =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [project],
        current_project_id: "prj_1",
        capture_ask: "",
        capture_project_id: "prj_1",
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: false
      )

    assert html_empty =~ "id=\"capture-submit-button\""
    assert html_empty =~ "disabled"

    html_whitespace =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [project],
        current_project_id: "prj_1",
        capture_ask: "   \n\t  ",
        capture_project_id: "prj_1",
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: false
      )

    assert html_whitespace =~ "id=\"capture-submit-button\""
    assert html_whitespace =~ "disabled"
  end

  test "capture_issue_modal disables submit button and shows Adding when submitting" do
    project = %Project{id: "prj_1", name: "Alpha App", linear_team_key: nil, active: true}

    html =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [project],
        current_project_id: "prj_1",
        capture_ask: "Something valid",
        capture_project_id: "prj_1",
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: true
      )

    assert html =~ "id=\"capture-submit-button\""
    assert html =~ "disabled"
    assert html =~ "Adding..."
  end

  test "capture_issue_modal displays error banner when capture_error is set" do
    project = %Project{id: "prj_1", name: "Alpha App", active: true}

    html =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [project],
        current_project_id: "prj_1",
        capture_ask: "My ask",
        capture_project_id: "prj_1",
        capture_priority: :medium,
        capture_error: "Linear rejected the issue",
        capture_submitting: false
      )

    assert html =~ "id=\"capture-error-banner\""
    assert html =~ "data-qa=\"capture_error_banner\""
    assert html =~ "Linear rejected the issue"
  end

  test "capture_issue_modal defaults selected project to current_project_id or first active project" do
    project1 = %Project{id: "prj_1", name: "Alpha App", active: false}
    project2 = %Project{id: "prj_2", name: "Beta Core", active: true}
    project3 = %Project{id: "prj_3", name: "Gamma Lib", active: true}

    # When capture_project_id is nil, current_project_id is inactive -> falls back to first active (prj_2)
    html1 =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [project1, project2, project3],
        current_project_id: "prj_1",
        capture_ask: "",
        capture_project_id: nil,
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: false
      )

    assert html1 =~ "value=\"prj_2\" selected"

    # When capture_project_id is nil, current_project_id is active -> selects current (prj_3)
    html2 =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        visible: true,
        projects: [project1, project2, project3],
        current_project_id: "prj_3",
        capture_ask: "",
        capture_project_id: nil,
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: false
      )

    assert html2 =~ "value=\"prj_3\" selected"
  end

  test "capture_issue_modal handles show_new_issue_modal attr and hides when false" do
    html_hidden =
      render_component(&CaptureIssueModal.capture_issue_modal/1,
        show_new_issue_modal: false,
        projects: [],
        current_project_id: nil,
        capture_ask: "",
        capture_project_id: nil,
        capture_priority: :medium,
        capture_error: nil,
        capture_submitting: false
      )

    refute html_hidden =~ "id=\"capture-idea-dialog\""
    refute html_hidden =~ "data-qa=\"capture_idea_dialog\""
  end

  test "delegated CoreComponents.capture_issue_modal renders correctly" do
    html = render_component(&RailWeb.CoreComponents.capture_issue_modal/1, visible: false)
    refute html =~ "id=\"capture-idea-dialog\""
  end
end
