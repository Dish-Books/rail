defmodule RailWeb.Components.DemoPanelTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Components.DemoPanel

  test "renders recorded demo with fresh commit and play all button" do
    seg1 = %DemoSegment{
      criterion_index: 1,
      criterion: "Criterion 1: Auth flow works",
      outcome: :recorded,
      frames: [
        %DemoFrame{linear_asset_id: "ast_frame_1", hold_ms: 1000},
        %DemoFrame{linear_asset_id: "ast_frame_2", hold_ms: 500}
      ]
    }

    seg2 = %DemoSegment{
      criterion_index: 2,
      criterion: "Criterion 2: Profile updates",
      outcome: :not_filmable,
      note: "Background job execution"
    }

    demo = %Demo{
      version: 1,
      outcome: "recorded",
      commit: "abc1234",
      stale: false,
      segments: [seg1, seg2]
    }

    task = %Task{
      id: "tsk_demo_1",
      stage: :engineer,
      stage_state: :running
    }

    html = render_component(&DemoPanel.demo_panel/1, demo: demo, task: task)

    assert html =~ "id=\"demo-panel\""
    assert html =~ "id=\"demo-panel-title\""
    assert html =~ "Recorded demo"
    assert html =~ "id=\"demo-version-pill\""
    assert html =~ "v1"
    assert html =~ "id=\"demo-recorded-count-pill\""
    assert html =~ "1/2 recorded"
    assert html =~ "id=\"demo-commit-pill\""
    assert html =~ "Matches abc1234"

    # Play all button enabled
    assert html =~ "id=\"demo-play-all-btn\""
    assert html =~ "Play all"
    refute html =~ "id=\"demo-play-all-btn\"[^\>]*disabled"

    # Criterion 1: Recorded
    assert html =~ "id=\"demo-criterion-card-0\""
    assert html =~ "Criterion 1"
    assert html =~ "Recorded"
    assert html =~ "Criterion 1: Auth flow works"
    assert html =~ "/assets/demo/ast_frame_1"
    assert html =~ "2 frames • 1.5s"
    assert html =~ "1.5s"
    assert html =~ "id=\"demo-criterion-play-btn-0\""

    # Criterion 2: Not filmable
    assert html =~ "id=\"demo-criterion-card-1\""
    assert html =~ "Criterion 2"
    assert html =~ "Not filmable"
    assert html =~ "Criterion 2: Profile updates"
    assert html =~ "Background job execution"
  end

  test "renders declined demo with note and no recorded count pill" do
    seg = %{
      criterion_index: 1,
      criterion: "AC 1",
      outcome: "recorded",
      frames: [%{hold_ms: 1000}]
    }

    demo = %{
      version: 2,
      outcome: "declined",
      note: "Feature is CLI only and cannot be demonstrated in browser",
      commit: "def5678",
      stale: false,
      segments: [seg]
    }

    task = %Task{
      id: "tsk_demo_2",
      stage: :engineer,
      stage_state: :running
    }

    html = render_component(&DemoPanel.demo_panel/1, demo: demo, task: task)

    assert html =~ "id=\"demo-panel-title\""
    assert html =~ "Demo declined"
    assert html =~ "v2"

    # Declined demo shows NO pill containing "recorded"
    refute html =~ "data-qa=\"demo_recorded_count_pill\""
    refute html =~ "recorded</span"

    # Declined note card
    assert html =~ "id=\"demo-declined-card\""
    assert html =~ "Demo declined: Feature is CLI only and cannot be demonstrated in browser"

    # Play all button omitted for declined demo
    refute html =~ "id=\"demo-play-all-btn\""
  end

  test "renders stale demo with out of date pill, opacity-50, and disabled play buttons" do
    File.mkdir_p!("/tmp/wt")
    seg = %{
      criterion_index: 1,
      criterion: "AC 1",
      outcome: "recorded",
      frames: [%{url: "https://example.com/f1.png", hold_ms: 1000}]
    }

    demo = %{
      version: 1,
      outcome: "recorded",
      commit: "stale999",
      stale: true,
      segments: [seg]
    }

    task = %{
      stage: :ready_to_merge,
      stage_state: :awaiting_approval,
      worktree_path: "/tmp/wt"
    }

    html = render_component(&DemoPanel.demo_panel/1, demo: demo, task: task)

    assert html =~ "Out of date (stale999)"
    assert html =~ "bg-red-100 dark:bg-red-900"

    # Play all is disabled
    assert html =~ "id=\"demo-play-all-btn\""
    assert html =~ "disabled"

    # Criterion card is wrapped in opacity-50
    assert html =~ "opacity-50"
    assert html =~ "id=\"demo-criterion-play-btn-0\""
    assert html =~ "disabled"

    # Re-record button shown when task is eligible
    assert html =~ "id=\"demo-rerecord-btn\""
    assert html =~ "Re-record"
  end

  test "renders failed criterion card outcome accurately" do
    seg = %{
      criterion_index: 3,
      criterion: "AC 3: Edge cases handled",
      outcome: "failed",
      frames: []
    }

    demo = %{
      version: 1,
      outcome: "failed",
      segments: [seg]
    }

    html = render_component(&DemoPanel.demo_panel/1, demo: demo, task: nil)

    assert html =~ "Criterion 3"
    assert html =~ "Failed"
    assert html =~ "AC 3: Edge cases handled"
  end

  test "handles explicit duration_ms, not_filmable string outcome, and nil demo" do
    seg_explicit = %{
      criterion_index: 1,
      criterion: "Explicit duration",
      outcome: "not_filmable",
      duration_ms: 2500,
      frames: []
    }

    demo = %{
      "version" => 2,
      "outcome" => "recorded",
      "segments" => [seg_explicit, nil]
    }

    html = render_component(&DemoPanel.demo_panel/1, demo: demo, task: nil)
    assert html =~ "Criterion 1"
    assert html =~ "Not filmable"
    assert html =~ "Explicit duration"

    # nil demo
    nil_html = render_component(&DemoPanel.demo_panel/1, demo: nil, task: nil)
    assert nil_html =~ "id=\"demo-panel\""
  end
end
