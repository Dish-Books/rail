defmodule RailWeb.Components.DemoPlayerModalTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias RailWeb.Components.DemoPlayerModal
  alias RailWeb.Components.DemoPlayerState

  test "renders empty state when player has no segments" do
    player = DemoPlayerState.new(nil)
    html = render_component(&DemoPlayerModal.demo_player_modal/1, player: player)

    assert html =~ "id=\"demo-player-modal\""
    assert html =~ "id=\"demo-player-empty-state\""
    assert html =~ "No demo segments available."
    assert html =~ "id=\"demo-player-empty-close-btn\""
    assert html =~ "phx-click=\"close_demo_player\""
  end

  test "renders header, frame image, caption, and controls when segments are present" do
    frame1 = %DemoFrame{
      url: "https://linear.app/asset/frame_1.png",
      hold_ms: 1000,
      caption: "Step 1: Welcome page loaded"
    }

    frame2 = %DemoFrame{
      url: "https://linear.app/asset/frame_2.png",
      hold_ms: 2000,
      caption: "Step 2: User clicks sign in"
    }

    seg1 = %DemoSegment{
      criterion_index: 1,
      criterion: "Criterion 1: Auth flow",
      frames: [frame1, frame2]
    }

    seg2 = %DemoSegment{
      criterion_index: 2,
      criterion: "Criterion 2: Dashboard",
      frames: [%DemoFrame{url: "https://linear.app/asset/frame_3.png", hold_ms: 1500}]
    }

    demo = %{segments: [seg1, seg2]}
    player = DemoPlayerState.new(demo, is_playing: false)

    html = render_component(&DemoPlayerModal.demo_player_modal/1, player: player)

    assert html =~ "id=\"demo-player-modal\""
    assert html =~ "phx-hook=\"DemoPlayer\""

    # Header
    assert html =~ "id=\"demo-player-header\""
    assert html =~ "Criterion 1 of 2"
    assert html =~ "Criterion 1: Auth flow"
    assert html =~ "id=\"demo-player-close-btn\""

    # Frame & caption
    assert html =~ "id=\"demo-player-frame-img\""
    assert html =~ "https://linear.app/asset/frame_1.png"
    assert html =~ "id=\"demo-player-caption-overlay\""
    assert html =~ "Step 1: Welcome page loaded"

    # Scrubber
    assert html =~ "id=\"demo-player-slider\""
    assert html =~ "0.0s"
    assert html =~ "3.0s"

    # Transport controls
    assert html =~ "id=\"demo-player-play-toggle\""
    assert html =~ "data-playing=\"false\""
    assert html =~ "title=\"Play\""

    # Prev segment disabled at start
    assert html =~ ~r/id="demo-player-prev-segment"[^>]*disabled/
    # Next segment enabled
    refute html =~ ~r/id="demo-player-next-segment"[^>]*disabled/

    # Loop button off
    assert html =~ "id=\"demo-player-loop-toggle\""
    assert html =~ "title=\"Looping off\""
  end

  test "renders pause button when is_playing is true and active loop styling" do
    seg = %{
      criterion_index: 1,
      criterion: "Single segment",
      frames: [%{url: "https://example.com/f.png", hold_ms: 1000, caption: nil}]
    }

    demo = %{segments: [seg]}
    player = DemoPlayerState.new(demo, is_playing: true, loop: true)

    html = render_component(&DemoPlayerModal.demo_player_modal/1, player: player)

    assert html =~ "id=\"demo-player-play-toggle\""
    assert html =~ "data-playing=\"true\""
    assert html =~ "title=\"Pause\""
    assert html =~ "title=\"Looping on\""
  end

  test "renders fallback state when frame has no URL" do
    seg = %{
      criterion_index: 1,
      criterion: "Missing frame URL",
      frames: [%{url: nil, path: nil, caption: nil}]
    }

    demo = %{segments: [seg]}
    player = DemoPlayerState.new(demo)

    html = render_component(&DemoPlayerModal.demo_player_modal/1, player: player)

    assert html =~ "id=\"demo-player-frame-area\""
    refute html =~ "id=\"demo-player-frame-img\""
    refute html =~ "id=\"demo-player-caption-overlay\""
  end

  test "handles non-map segment and non-integer duration gracefully" do
    player = %DemoPlayerState{
      segments: [:not_a_map],
      segment_index: 0,
      elapsed_ms: :not_int
    }

    html = render_component(&DemoPlayerModal.demo_player_modal/1, player: player)
    assert html =~ "id=\"demo-player-modal\""
    assert html =~ "Criterion 1 of 1"
    assert html =~ "0.0s"
  end
end
