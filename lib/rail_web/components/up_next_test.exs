defmodule RailWeb.Components.UpNextTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role
  alias RailWeb.Components.UpNext

  setup do
    waiting = fn stage ->
      %Run{
        id: "run_#{stage}",
        task_id: "tsk_#{stage}",
        status: :finished,
        stage_outcome: :done,
        completed_at: ~U[2026-01-01 10:00:00Z],
        questions: [],
        role: %Role{name: "#{stage} role", icon_name: "pi-robot", stage: stage},
        task: %Task{stage: stage, issue: %Issue{identifier: "UPN-1", title: "Invoice filters"}}
      }
    end

    %{waiting: waiting}
  end

  test "says nothing is waiting when nothing is" do
    assert render_component(&UpNext.up_next/1, runs: []) =~ "Nothing is waiting on you."
  end

  test "names the work each stage is holding out for review", %{waiting: waiting} do
    for {stage, work} <- [product: "ticket", design: "design", architect: "plan", engineer: "implementation"] do
      html = render_component(&UpNext.up_next/1, runs: [waiting.(stage)])

      assert html =~ "The #{work} is ready for you to review."
    end
  end

  test "the longest-waiting leads and the rest follow as rows", %{waiting: waiting} do
    engineer = waiting.(:engineer)
    architect = waiting.(:architect)

    html = render_component(&UpNext.up_next/1, runs: [engineer, architect])

    assert html =~ "up-next-featured-run_engineer"
    assert html =~ "plan ready for review"
  end

  test "a blocked run leads with what it asked", %{waiting: waiting} do
    blocked = %{
      waiting.(:engineer)
      | status: :blocked_on_input,
        stage_outcome: :in_progress,
        questions: [%Question{status: :pending, prompt: "Which vendor field?"}]
    }

    assert render_component(&UpNext.up_next/1, runs: [blocked]) =~ "Which vendor field?"
  end

  test "a run whose questions are all answered is waiting to be sent", %{waiting: waiting} do
    answered = %{
      waiting.(:engineer)
      | status: :blocked_on_input,
        stage_outcome: :in_progress,
        questions: [
          %Question{status: :answered, prompt: "Which vendor field?"},
          %Question{status: :answered, prompt: "Which index?"}
        ]
    }

    html = render_component(&UpNext.up_next/1, runs: [answered, answered])

    assert html =~ "Every question is answered and ready to send."
    assert html =~ "asked 2 questions"
  end

  test "a run that asked one thing says so in the singular", %{waiting: waiting} do
    one = %{
      waiting.(:engineer)
      | status: :blocked_on_input,
        stage_outcome: :in_progress,
        questions: [%Question{status: :answered, prompt: "Which vendor field?"}]
    }

    assert render_component(&UpNext.up_next/1, runs: [one, one]) =~ "asked a question"
  end
end
