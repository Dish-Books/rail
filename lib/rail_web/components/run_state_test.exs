defmodule RailWeb.Components.RunStateTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Runs.Schemas.Run
  alias RailWeb.Components.RunState

  test "each state has its own icon" do
    task = %Task{stage: :review}

    assert RunState.icon(task, nil) == "pi-clock"
    assert RunState.icon(task, %Run{status: :running}) == "pi-play-circle"
    assert RunState.icon(task, %Run{status: :blocked_on_input}) == "pi-question"
    assert RunState.icon(task, %Run{status: :finished, error: "boom"}) == "pi-warning-circle"
    assert RunState.icon(task, %Run{status: :finished}) == "pi-pause-circle"
    assert RunState.icon(task, %Run{status: :finished, stage_outcome: :done}) == "pi-chat-text"
  end

  test "a task ready to merge shows the merge rather than a conversation" do
    task = %Task{stage: :ready_to_merge}

    assert RunState.icon(task, %Run{status: :finished, stage_outcome: :done}) == "pi-git-merge"
  end

  test "a branch that cannot merge outranks whatever the run said" do
    conflicted = %Task{stage: :review, mergeability: :conflicting}

    assert RunState.icon(conflicted, %Run{status: :running}) == "pi-git-branch"
    assert RunState.color(conflicted, %Run{status: :running}) == :amber
  end

  test "colour follows what the run is doing" do
    task = %Task{stage: :review}

    assert RunState.color(task, %Run{status: :running}) == :primary
    assert RunState.color(task, %Run{status: :blocked_on_input}) == :amber
    assert RunState.color(task, %Run{status: :finished, stage_outcome: :done}) == :amber
    assert RunState.color(task, %Run{status: :finished, error: "boom"}) == :error
    assert RunState.color(task, nil) == :outline
  end

  test "the classes say the same thing as text and as a chip" do
    task = %Task{stage: :review}

    assert RunState.color_class(task, %Run{status: :running}) =~ "text-blue"
    assert RunState.color_class(task, %Run{status: :blocked_on_input}) =~ "text-amber"
    assert RunState.color_class(task, %Run{status: :finished, error: "boom"}) =~ "text-red"
    assert RunState.color_class(task, nil) =~ "text-slate"

    assert RunState.color_class(task, %Run{status: :running}, :chip) =~ "bg-blue"
    assert RunState.color_class(task, %Run{status: :blocked_on_input}, :chip) =~ "bg-amber"
    assert RunState.color_class(task, %Run{status: :finished, error: "boom"}, :chip) =~ "bg-red"
    assert RunState.color_class(task, nil, :chip) =~ "bg-slate"
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
