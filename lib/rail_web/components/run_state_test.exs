defmodule RailWeb.Components.RunStateTest do
  use ExUnit.Case, async: true

  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.RunState

  test "each state has its own icon" do
    assert RunState.icon(nil) == "pi-clock"
    assert RunState.icon(%Run{status: :running}) == "pi-play-circle"
    assert RunState.icon(%Run{status: :blocked_on_input}) == "pi-question"
    assert RunState.icon(%Run{status: :finished, error: "boom"}) == "pi-warning-circle"
    assert RunState.icon(%Run{status: :finished}) == "pi-pause-circle"
    assert RunState.icon(%Run{status: :finished, stage_outcome: :done}) == "pi-chat-text"
  end

  test "colour follows what the run is doing" do
    assert RunState.color(%Run{status: :running}) == :primary
    assert RunState.color(%Run{status: :blocked_on_input}) == :amber
    assert RunState.color(%Run{status: :finished, stage_outcome: :done}) == :amber
    assert RunState.color(%Run{status: :finished, error: "boom"}) == :error
    assert RunState.color(nil) == :outline
  end

  test "the classes say the same thing as text and as a chip" do
    assert RunState.color_class(%Run{status: :running}) =~ "text-blue"
    assert RunState.color_class(%Run{status: :blocked_on_input}) =~ "text-amber"
    assert RunState.color_class(%Run{status: :finished, error: "boom"}) =~ "text-red"
    assert RunState.color_class(nil) =~ "text-slate"

    assert RunState.color_class(%Run{status: :running}, :chip) =~ "bg-blue"
    assert RunState.color_class(%Run{status: :blocked_on_input}, :chip) =~ "bg-amber"
    assert RunState.color_class(%Run{status: :finished, error: "boom"}, :chip) =~ "bg-red"
    assert RunState.color_class(nil, :chip) =~ "bg-slate"
  end

  test "a pill says the state in a word" do
    assert RunState.pill_label(:running) == "Running"
    assert RunState.pill_label(:blocked) == "Needs you"
    assert RunState.pill_label(:failed) == "Failed"
    assert RunState.pill_label(:done) == "Done"
    assert RunState.pill_label(:stopped) == "Stopped"
    assert RunState.pill_label(:queued) == "Queued"

    assert RunState.pill_class(:running) =~ "bg-blue"
    assert RunState.pill_class(:queued) =~ "bg-slate"
  end
end
