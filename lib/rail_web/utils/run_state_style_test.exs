defmodule RailWeb.Utils.RunStateStyleTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.RunStateStyle

  alias Rail.Pipeline.Schemas.Run

  test "icon follows the run's state" do
    assert run_state_style(nil).icon == "pi-clock"
    assert run_state_style(%Run{status: :running}).icon == "pi-play-circle"
    assert run_state_style(%Run{status: :blocked_on_input}).icon == "pi-question"
    assert run_state_style(%Run{status: :finished, error: "boom"}).icon == "pi-warning-circle"
    assert run_state_style(%Run{status: :finished}).icon == "pi-pause-circle"
    assert run_state_style(%Run{status: :finished, stage_outcome: :done}).icon == "pi-chat-text"
  end

  test "text and chip classes share the state's colour" do
    assert run_state_style(%Run{status: :running}).text_class =~ "text-blue"
    assert run_state_style(%Run{status: :blocked_on_input}).text_class =~ "text-amber"
    assert run_state_style(%Run{status: :finished, stage_outcome: :done}).text_class =~ "text-amber"
    assert run_state_style(%Run{status: :finished, error: "boom"}).text_class =~ "text-red"
    assert run_state_style(nil).text_class =~ "text-slate"

    assert run_state_style(%Run{status: :running}).chip_class =~ "bg-blue"
    assert run_state_style(%Run{status: :blocked_on_input}).chip_class =~ "bg-amber"
    assert run_state_style(%Run{status: :finished, error: "boom"}).chip_class =~ "bg-red"
    assert run_state_style(nil).chip_class =~ "bg-slate"
  end

  test "pill label names the state" do
    assert run_state_style(%Run{status: :running}).pill_label == "Running"
    assert run_state_style(%Run{status: :blocked_on_input}).pill_label == "Needs you"
    assert run_state_style(%Run{status: :finished, error: "boom"}).pill_label == "Failed"
    assert run_state_style(%Run{status: :finished, stage_outcome: :done}).pill_label == "Done"
    assert run_state_style(%Run{status: :finished}).pill_label == "Stopped"
    assert run_state_style(nil).pill_label == "Queued"
  end
end
