defmodule RailWeb.Components.UpNextTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RailWeb.Utils.StageLabel

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

  # A card and the page it opens have to name the errand the same way, so both
  # read it off `StageLabel.approval_label/1`.
  test "names the work each stage is holding out for review", %{waiting: waiting} do
    for stage <- [:product, :design, :architect, :engineer, :review, :qa] do
      html = render_component(&UpNext.up_next/1, runs: [waiting.(stage)])

      assert html =~ approval_label(stage)
    end
  end

  test "says what is waiting to be read, however many of it there is", %{waiting: waiting} do
    for {stage, work} <- [product: "ticket", design: "designs", review: "findings", qa: "QA report"] do
      html = render_component(&UpNext.up_next/1, runs: [waiting.(stage)])

      assert html =~ "Waiting on you to read the #{work}."
    end
  end

  test "the longest-waiting leads and the rest follow as rows", %{waiting: waiting} do
    engineer = waiting.(:engineer)
    architect = waiting.(:architect)

    html = render_component(&UpNext.up_next/1, runs: [engineer, architect])

    assert html =~ "up-next-featured-run_engineer"
    assert html =~ "plan ready for review"
  end

  test "a failed run leads with the error, and reads as a problem", %{waiting: waiting} do
    failed = %{waiting.(:engineer) | stage_outcome: :in_progress, error: "The engineer changed nothing."}

    html = render_component(&UpNext.up_next/1, runs: [failed])

    assert html =~ "Needs a fix"
    assert html =~ "The engineer changed nothing."
    assert html =~ "Pick it up"
    assert html =~ "bg-red-500"
  end

  test "a run that stopped without concluding says how to resume it", %{waiting: waiting} do
    stopped = %{waiting.(:engineer) | stage_outcome: :in_progress}

    html = render_component(&UpNext.up_next/1, runs: [stopped])

    assert html =~ "Needs a fix"
    assert html =~ "stopped before finishing"
  end

  test "a stalled run in the rows says the same thing", %{waiting: waiting} do
    stalled = %{waiting.(:engineer) | stage_outcome: :in_progress, error: "It went wrong"}

    html = render_component(&UpNext.up_next/1, runs: [waiting.(:architect), stalled])

    assert html =~ "It went wrong"
    assert html =~ "Fix"
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

  test "a change whose demo is recorded is ready to merge, and opens on the demo", %{waiting: waiting} do
    demo = waiting.(:demo)
    ready = %{demo | role_id: "rol_demo", task: %{demo.task | pr_url: "https://github.com/org/app/pull/12"}}

    html = render_component(&UpNext.up_next/1, runs: [ready])

    assert html =~ ~s(href="/tasks/tsk_demo?tab=rol_demo")
    assert html =~ "Ready to merge"
    assert html =~ "The demo is recorded, and the pull request is waiting on you to merge it."

    html = render_component(&UpNext.up_next/1, runs: [waiting.(:engineer), %{ready | id: "run_ready"}])

    assert html =~ "demo recorded"
    assert html =~ ~s(href="/tasks/tsk_demo?tab=rol_demo")
  end

  test "a recorded demo with no pull request to merge is watched on the task page", %{waiting: waiting} do
    html = render_component(&UpNext.up_next/1, runs: [waiting.(:demo)])

    assert html =~ "Watch the demo"
    assert html =~ ~s(href="/tasks/tsk_demo")
    refute html =~ "Ready to merge"
  end
end
