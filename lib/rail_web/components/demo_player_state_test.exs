defmodule RailWeb.Components.DemoPlayerStateTest do
  use ExUnit.Case, async: true

  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias RailWeb.Components.DemoPlayerState

  test "new/2 initializes state with defaults and clamps initial segment" do
    demo = %{
      segments: [
        %{criterion_index: 1, criterion: "Criterion 1", frames: [%{hold_ms: 1000}]},
        %{criterion_index: 2, criterion: "Criterion 2", frames: [%{hold_ms: 2000}]}
      ]
    }

    state = DemoPlayerState.new(demo)
    assert %DemoPlayerState{segment_index: 0, frame_index: 0, elapsed_ms: 0, is_playing: false, loop: false} = state

    clamped_state = DemoPlayerState.new(demo, segment_index: 99, loop: true, is_playing: true)
    assert %DemoPlayerState{segment_index: 1, loop: true, is_playing: true} = clamped_state

    empty_state = DemoPlayerState.new(nil)
    assert %DemoPlayerState{segments: [], segment_index: 0} = empty_state

    string_keyed_demo = %{
      "segments" => [
        %{"criterion_index" => 1, "criterion" => "AC1", "frames" => [%{"hold_ms" => 500}]}
      ]
    }

    string_state = DemoPlayerState.new(string_keyed_demo)
    assert %DemoPlayerState{segments: [_segment]} = string_state

    non_map_state = DemoPlayerState.new(:invalid)
    assert %DemoPlayerState{segments: []} = non_map_state

    invalid_index_state = DemoPlayerState.new(demo, segment_index: :invalid)
    assert %DemoPlayerState{segment_index: 0} = invalid_index_state
  end

  test "current_segment/1 and current_frame/1 return appropriate data and fallbacks" do
    frame1 = %DemoFrame{url: "https://example.com/1.png", hold_ms: 1200, caption: "Frame 1"}
    frame2 = %DemoFrame{url: "https://example.com/2.png", hold_ms: 800, caption: "Frame 2"}
    segment = %DemoSegment{criterion_index: 1, criterion: "AC 1", frames: [frame1, frame2]}
    demo = %{segments: [segment]}

    state = DemoPlayerState.new(demo)
    assert %DemoSegment{criterion_index: 1} = DemoPlayerState.current_segment(state)
    assert %DemoFrame{caption: "Frame 1"} = DemoPlayerState.current_frame(state)

    state_frame2 = %{state | frame_index: 1}
    assert %DemoFrame{caption: "Frame 2"} = DemoPlayerState.current_frame(state_frame2)

    # Empty segment has synthetic frame fallback
    empty_seg = %DemoSegment{criterion_index: 2, criterion: "AC 2", frames: []}
    state_empty = DemoPlayerState.new(%{segments: [empty_seg]})
    assert %DemoFrame{hold_ms: 1000} = DemoPlayerState.current_frame(state_empty)

    # No segments has nil segment and synthetic frame fallback
    no_seg_state = DemoPlayerState.new(nil)
    assert is_nil(DemoPlayerState.current_segment(no_seg_state))
    assert %DemoFrame{hold_ms: 1000} = DemoPlayerState.current_frame(no_seg_state)
  end

  test "total_segment_ms/1 calculates duration across frames or explicit field" do
    demo_struct = %{
      segments: [
        %DemoSegment{frames: [%DemoFrame{hold_ms: 500}, %DemoFrame{hold_ms: 1500}]}
      ]
    }

    state = DemoPlayerState.new(demo_struct)
    assert DemoPlayerState.total_segment_ms(state) == 2000

    explicit_ms = %{segments: [%{duration_ms: 4500, frames: []}]}
    assert DemoPlayerState.total_segment_ms(DemoPlayerState.new(explicit_ms)) == 4500

    string_explicit_ms = %{"segments" => [%{"duration_ms" => 3200}]}
    assert DemoPlayerState.total_segment_ms(DemoPlayerState.new(string_explicit_ms)) == 3200

    empty_segment_ms = %{segments: [%{}]}
    assert DemoPlayerState.total_segment_ms(DemoPlayerState.new(empty_segment_ms)) == 1000

    assert DemoPlayerState.total_segment_ms(DemoPlayerState.new(nil)) == 0
  end

  test "navigation predicates check bounds accurately" do
    demo = %{
      segments: [
        %{frames: [%{hold_ms: 1000}, %{hold_ms: 1000}]},
        %{frames: [%{hold_ms: 1000}]}
      ]
    }

    state = DemoPlayerState.new(demo)
    refute DemoPlayerState.has_prev_segment?(state)
    assert DemoPlayerState.has_next_segment?(state)
    refute DemoPlayerState.has_prev_frame?(state)
    assert DemoPlayerState.has_next_frame?(state)

    state_last_frame_seg0 = %{state | frame_index: 1}
    assert DemoPlayerState.has_prev_frame?(state_last_frame_seg0)
    assert DemoPlayerState.has_next_frame?(state_last_frame_seg0)

    state_seg1 = %{state | segment_index: 1, frame_index: 0}
    assert DemoPlayerState.has_prev_segment?(state_seg1)
    refute DemoPlayerState.has_next_segment?(state_seg1)
    assert DemoPlayerState.has_prev_frame?(state_seg1)
    refute DemoPlayerState.has_next_frame?(state_seg1)

    # With loop on, prev and next frame are available
    state_loop = %{state_seg1 | loop: true}
    assert DemoPlayerState.has_prev_frame?(state_loop)
    assert DemoPlayerState.has_next_frame?(state_loop)

    # Empty segments
    empty_state = DemoPlayerState.new(nil)
    refute DemoPlayerState.has_prev_segment?(empty_state)
    refute DemoPlayerState.has_next_segment?(empty_state)
    refute DemoPlayerState.has_prev_frame?(empty_state)
    refute DemoPlayerState.has_next_frame?(empty_state)
  end

  test "play/1, pause/1, and toggle_play_pause/1 control play state" do
    demo = %{segments: [%{frames: [%{hold_ms: 1000}]}]}
    state = DemoPlayerState.new(demo)

    played = DemoPlayerState.play(state)
    assert %DemoPlayerState{is_playing: true} = played

    assert ^played = DemoPlayerState.play(played)

    paused = DemoPlayerState.pause(played)
    assert %DemoPlayerState{is_playing: false} = paused

    toggled_on = DemoPlayerState.toggle_play_pause(paused)
    assert %DemoPlayerState{is_playing: true} = toggled_on

    toggled_off = DemoPlayerState.toggle_play_pause(toggled_on)
    assert %DemoPlayerState{is_playing: false} = toggled_off

    # Play when empty segments is a no-op
    empty_state = DemoPlayerState.new(nil)
    assert %DemoPlayerState{is_playing: false} = DemoPlayerState.play(empty_state)

    # Play when at end of segment advances to next segment or seeks to 0
    demo_two_seg = %{
      segments: [
        %{frames: [%{hold_ms: 1000}]},
        %{frames: [%{hold_ms: 1000}]}
      ]
    }

    at_end_seg0 = %{DemoPlayerState.new(demo_two_seg) | elapsed_ms: 1000}
    advanced = DemoPlayerState.play(at_end_seg0)
    assert %DemoPlayerState{segment_index: 1, elapsed_ms: 0, is_playing: true} = advanced

    at_end_seg1 = %{DemoPlayerState.new(demo_two_seg, segment_index: 1) | elapsed_ms: 1000}
    reset_to_start = DemoPlayerState.play(at_end_seg1)
    assert %DemoPlayerState{segment_index: 1, elapsed_ms: 0, is_playing: true} = reset_to_start
  end

  test "seek/2 updates elapsed_ms and recalculates frame_index" do
    demo = %{
      segments: [
        %{
          frames: [
            %{hold_ms: 1000},
            %{hold_ms: 1500},
            %{hold_ms: 2000}
          ]
        }
      ]
    }

    state = DemoPlayerState.new(demo)

    assert %DemoPlayerState{elapsed_ms: 500, frame_index: 0} = DemoPlayerState.seek(state, 500)
    assert %DemoPlayerState{elapsed_ms: 1500, frame_index: 1} = DemoPlayerState.seek(state, 1500)
    assert %DemoPlayerState{elapsed_ms: 3000, frame_index: 2} = DemoPlayerState.seek(state, 3000)

    # Clamping below 0 and above total
    assert %DemoPlayerState{elapsed_ms: 0, frame_index: 0} = DemoPlayerState.seek(state, -100)
    assert %DemoPlayerState{elapsed_ms: 4500, frame_index: 2} = DemoPlayerState.seek(state, 9999)

    # Seek with empty segments
    empty_state = DemoPlayerState.new(nil)
    assert %DemoPlayerState{elapsed_ms: 0, frame_index: 0} = DemoPlayerState.seek(empty_state, 500)
  end

  test "next_frame/1 advances within segment and across segments" do
    demo = %{
      segments: [
        %{frames: [%{hold_ms: 1000}, %{hold_ms: 1200}]},
        %{frames: [%{hold_ms: 1500}]}
      ]
    }

    state = DemoPlayerState.new(demo)

    f1 = DemoPlayerState.next_frame(state)
    assert %DemoPlayerState{segment_index: 0, frame_index: 1, elapsed_ms: 1000} = f1

    f2 = DemoPlayerState.next_frame(f1)
    assert %DemoPlayerState{segment_index: 1, frame_index: 0, elapsed_ms: 0} = f2

    # At last frame of last segment without loop does not advance
    f3 = DemoPlayerState.next_frame(f2)
    assert ^f2 = f3

    # With loop, loops back to segment 0 frame 0
    with_loop = %{f2 | loop: true}
    looped = DemoPlayerState.next_frame(with_loop)
    assert %DemoPlayerState{segment_index: 0, frame_index: 0, elapsed_ms: 0} = looped

    # Empty segments
    assert %DemoPlayerState{} = DemoPlayerState.next_frame(DemoPlayerState.new(nil))
  end

  test "prev_frame/1 steps back within segment and lands on previous segment's last frame" do
    demo = %{
      segments: [
        %{frames: [%{hold_ms: 1000}, %{hold_ms: 1200}]},
        %{frames: [%{hold_ms: 1500}, %{hold_ms: 800}]}
      ]
    }

    state = %{DemoPlayerState.new(demo, segment_index: 1) | frame_index: 1, elapsed_ms: 1500}

    back_one = DemoPlayerState.prev_frame(state)
    assert %DemoPlayerState{segment_index: 1, frame_index: 0, elapsed_ms: 0} = back_one

    to_prev_seg = DemoPlayerState.prev_frame(back_one)
    assert %DemoPlayerState{segment_index: 0, frame_index: 1, elapsed_ms: 1000} = to_prev_seg

    to_first_frame = DemoPlayerState.prev_frame(to_prev_seg)
    assert %DemoPlayerState{segment_index: 0, frame_index: 0, elapsed_ms: 0} = to_first_frame

    # At first frame without loop stays at 0
    assert ^to_first_frame = DemoPlayerState.prev_frame(to_first_frame)

    # With loop, wraps to last segment last frame
    with_loop = %{to_first_frame | loop: true}
    looped_back = DemoPlayerState.prev_frame(with_loop)
    assert %DemoPlayerState{segment_index: 1, frame_index: 1, elapsed_ms: 1500} = looped_back

    # Empty segments
    assert %DemoPlayerState{} = DemoPlayerState.prev_frame(DemoPlayerState.new(nil))
    # frame_index > 0 with nil segment
    assert %DemoPlayerState{frame_index: 2} = DemoPlayerState.prev_frame(%DemoPlayerState{frame_index: 2, segments: []})

    # String-keyed frames map
    string_demo = %{"segments" => [%{"criterion_index" => 1, "frames" => [%{"hold_ms" => 500}, %{"hold_ms" => 600}]}]}
    string_player = DemoPlayerState.new(string_demo)
    advanced_string = DemoPlayerState.next_frame(string_player)
    assert %DemoPlayerState{frame_index: 1, elapsed_ms: 500} = advanced_string
  end

  test "next_segment/1 and prev_segment/1 jump between segments" do
    demo = %{
      segments: [
        %{frames: [%{hold_ms: 1000}]},
        %{frames: [%{hold_ms: 1200}]},
        %{frames: [%{hold_ms: 1500}]}
      ]
    }

    state = DemoPlayerState.new(demo)

    s1 = DemoPlayerState.next_segment(state)
    assert %DemoPlayerState{segment_index: 1, frame_index: 0, elapsed_ms: 0} = s1

    s2 = DemoPlayerState.next_segment(s1)
    assert %DemoPlayerState{segment_index: 2, frame_index: 0, elapsed_ms: 0} = s2

    # At end without loop
    assert ^s2 = DemoPlayerState.next_segment(s2)

    # At end with loop
    looped_s0 = DemoPlayerState.next_segment(%{s2 | loop: true})
    assert %DemoPlayerState{segment_index: 0} = looped_s0

    # Prev segment
    p1 = DemoPlayerState.prev_segment(s2)
    assert %DemoPlayerState{segment_index: 1} = p1

    p0 = DemoPlayerState.prev_segment(p1)
    assert %DemoPlayerState{segment_index: 0} = p0

    # At start without loop
    assert ^p0 = DemoPlayerState.prev_segment(p0)

    # At start with loop
    looped_last = DemoPlayerState.prev_segment(%{p0 | loop: true})
    assert %DemoPlayerState{segment_index: 2} = looped_last

    # Empty segments
    assert %DemoPlayerState{} = DemoPlayerState.next_segment(DemoPlayerState.new(nil))
    assert %DemoPlayerState{} = DemoPlayerState.prev_segment(DemoPlayerState.new(nil))
  end

  test "toggle_loop/1 toggles loop flag" do
    state = DemoPlayerState.new(nil)
    refute state.loop

    toggled = DemoPlayerState.toggle_loop(state)
    assert toggled.loop

    untoggled = DemoPlayerState.toggle_loop(toggled)
    refute untoggled.loop
  end

  test "tick/2 handles playback progression, segment advance, loop, and pause on completion" do
    demo = %{
      segments: [
        %{frames: [%{hold_ms: 1000}, %{hold_ms: 1000}]},
        %{frames: [%{hold_ms: 1500}]}
      ]
    }

    # Not playing does not advance
    paused_state = DemoPlayerState.new(demo, is_playing: false)
    assert ^paused_state = DemoPlayerState.tick(paused_state, 100)

    # Empty segments does not advance
    empty_state = DemoPlayerState.new(nil, is_playing: true)
    assert ^empty_state = DemoPlayerState.tick(empty_state, 100)

    # Within segment advancement
    playing_state = DemoPlayerState.new(demo, is_playing: true)
    t1 = DemoPlayerState.tick(playing_state, 500)
    assert %DemoPlayerState{elapsed_ms: 500, frame_index: 0, is_playing: true} = t1

    t2 = DemoPlayerState.tick(t1, 600)
    assert %DemoPlayerState{elapsed_ms: 1100, frame_index: 1, is_playing: true} = t2

    # Advance to next segment when duration reached
    t3 = DemoPlayerState.tick(t2, 1000)
    assert %DemoPlayerState{segment_index: 1, frame_index: 0, elapsed_ms: 0, is_playing: true} = t3

    # Reach end of all segments without loop -> clamps and pauses
    t4 = DemoPlayerState.tick(t3, 2000)
    assert %DemoPlayerState{segment_index: 1, frame_index: 0, elapsed_ms: 1500, is_playing: false} = t4

    # Multi-segment with loop -> wraps to segment 0
    playing_loop = %{t3 | loop: true}
    t_loop = DemoPlayerState.tick(playing_loop, 2000)
    assert %DemoPlayerState{segment_index: 0, frame_index: 0, elapsed_ms: 0, is_playing: true} = t_loop

    # Single segment with loop -> wraps to elapsed 0
    single_seg_demo = %{segments: [%{frames: [%{hold_ms: 1000}]}]}
    single_loop = DemoPlayerState.new(single_seg_demo, is_playing: true, loop: true)
    t_single_loop = DemoPlayerState.tick(single_loop, 1200)
    assert %DemoPlayerState{segment_index: 0, frame_index: 0, elapsed_ms: 0, is_playing: true} = t_single_loop
  end

  test "frame_url/1, frame_hold_ms/1, and frame_caption/1 resolve frame attributes" do
    proxied_frame = %DemoFrame{linear_asset_id: "ast_demo_99", hold_ms: 1500, caption: "Caption text"}
    assert DemoPlayerState.frame_url(proxied_frame) == "/assets/demo/ast_demo_99"
    assert DemoPlayerState.frame_hold_ms(proxied_frame) == 1500
    assert DemoPlayerState.frame_caption(proxied_frame) == "Caption text"

    url_frame = %{url: "https://linear.app/asset/frame.png", hold_ms: 2000, caption: nil}
    assert DemoPlayerState.frame_url(url_frame) == "https://linear.app/asset/frame.png"
    assert DemoPlayerState.frame_hold_ms(url_frame) == 2000
    assert is_nil(DemoPlayerState.frame_caption(url_frame))

    path_frame = %{"path" => "/local/frame.png", "hold_ms" => 800, "caption" => "Local frame"}
    assert DemoPlayerState.frame_url(path_frame) == "/local/frame.png"
    assert DemoPlayerState.frame_hold_ms(path_frame) == 800
    assert DemoPlayerState.frame_caption(path_frame) == "Local frame"

    fallback_frame = %{}
    assert DemoPlayerState.frame_url(fallback_frame) == ""
    assert DemoPlayerState.frame_hold_ms(fallback_frame) == 1000
    assert is_nil(DemoPlayerState.frame_caption(fallback_frame))

    assert DemoPlayerState.frame_url(nil) == ""
    assert DemoPlayerState.frame_hold_ms(nil) == 1000
    assert is_nil(DemoPlayerState.frame_caption(nil))
  end
end
