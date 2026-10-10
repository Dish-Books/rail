defmodule RailWeb.Components.UpNextTest do
  use Rail.DataCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Question
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias RailWeb.Components.UpNext

  setup do
    scratch = Path.join(System.tmp_dir!(), "up_next_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    waiting = fn stage ->
      %Run{
        id: "run_#{stage}",
        task_id: "tsk_#{stage}",
        status: :finished,
        stage_outcome: :done,
        completed_at: ~U[2026-01-01 10:00:00Z],
        questions: [],
        role: %Role{name: "#{stage} role", icon_name: "pi-robot", stage: Task.role_stage(stage)},
        task: %Task{stage: stage, scratch_path: scratch, issue: %Issue{identifier: "UPN-1", title: "Invoice filters"}}
      }
    end

    %{waiting: waiting, scratch: scratch}
  end

  test "says nothing is waiting when nothing is" do
    assert render_component(&UpNext.up_next/1, runs: []) =~ "Nothing is waiting on you."
  end

  # The card's action is the row's verb, so the errand is named in one word wherever it shows.
  test "every card's action is its verb", %{waiting: waiting, scratch: scratch} do
    action = fn run ->
      (&UpNext.up_next/1)
      |> render_component(runs: [run])
      |> Floki.parse_fragment!()
      |> Floki.find("[data-qa=up-next-action]")
      |> Floki.text()
      |> String.trim()
    end

    asked = %{
      waiting.(:review)
      | status: :blocked_on_input,
        stage_outcome: :in_progress,
        questions: [%Question{status: :pending, prompt: "Which vendor field?"}]
    }

    stopped = %{waiting.(:review) | stage_outcome: :in_progress, conversation_id: "sess_up_next"}
    failed = %{stopped | error: "It went wrong"}

    assert ["Review", "Review", "Review", "Answer", "Fix", "Fix"] =
             Enum.map(
               [waiting.(:plan), waiting.(:engineer), waiting.(:review), asked, stopped, failed],
               action
             )

    options = for key <- ["a", "b"], do: %{"key" => key, "title" => String.upcase(key)}
    File.mkdir_p!(Path.join(scratch, "design"))
    File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))

    assert "Pick" = action.(waiting.(:plan))

    for run <- [waiting.(:plan), asked, stopped, failed] do
      html = render_component(&UpNext.up_next/1, runs: [run])

      refute html =~ "Review the findings"
      refute html =~ "Answer questions"
      refute html =~ "Pick it up"
    end
  end

  test "says what is waiting to be read, however many of it there is", %{waiting: waiting} do
    for {stage, work} <- [plan: "plan", engineer: "diff", review: "findings"] do
      html = render_component(&UpNext.up_next/1, runs: [waiting.(stage)])

      assert html =~ "Waiting on you to read the #{work}."
    end
  end

  test "the longest-waiting leads and the rest follow as rows", %{waiting: waiting} do
    engineer = waiting.(:engineer)
    plan = waiting.(:plan)

    html = render_component(&UpNext.up_next/1, runs: [engineer, plan])

    assert html =~ "up-next-featured-run_engineer"
    assert html =~ "plan ready for review"
  end

  test "a failed run leads with the error, and reads as a problem", %{waiting: waiting} do
    failed = %{waiting.(:engineer) | stage_outcome: :in_progress, error: "The engineer changed nothing."}

    html = render_component(&UpNext.up_next/1, runs: [failed])

    assert html =~ "Needs a fix"
    assert html =~ "The engineer changed nothing."
    assert html =~ ~r/data-qa="up-next-action".*>\s*Fix\s*</s
    assert html =~ "bg-red-500"
  end

  test "a run that stopped without concluding says how to resume it", %{waiting: waiting} do
    stopped = %{waiting.(:engineer) | stage_outcome: :in_progress, conversation_id: "sess_up_next"}

    html = render_component(&UpNext.up_next/1, runs: [stopped])

    assert html =~ "Needs a fix"
    assert html =~ "stopped before finishing. Send it a message to pick up where it left off."

    # A run with no conversation, such as one moved into Plan when it shipped, starts again from its brief.
    html = render_component(&UpNext.up_next/1, runs: [%{stopped | conversation_id: nil}])
    assert html =~ "stopped before finishing. Retry it to start again from its brief."
  end

  test "a stalled run in the rows says the same thing", %{waiting: waiting} do
    stalled = %{waiting.(:engineer) | stage_outcome: :in_progress, error: "It went wrong"}

    html = render_component(&UpNext.up_next/1, runs: [waiting.(:plan), stalled])

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

  test "a run whose questions are all dismissed is waiting to be closed, not sent", %{waiting: waiting} do
    dismissed = %{
      waiting.(:engineer)
      | status: :blocked_on_input,
        stage_outcome: :in_progress,
        questions: [
          %Question{status: :answered, prompt: "From an earlier round", delivered_at: DateTime.utc_now()},
          %Question{status: :dismissed, prompt: "Which vendor field?"},
          %Question{status: :dismissed, prompt: "Which index?"}
        ]
    }

    html = render_component(&UpNext.up_next/1, runs: [dismissed])

    assert html =~ "Every question is dismissed. Close the round from the task."
    refute html =~ "ready to send"
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

  test "a Review run done with its review finished is ready to merge, and opens on Review", %{
    project: project,
    waiting: waiting
  } do
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    task = learnings_task(project, "UPN-2", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, %Task{id: task_id} = task} = Pipeline.update_task(task, %{pr_url: "https://github.com/org/app/pull/12"})

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{
        task_id: task_id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    {:ok, _pass} = Pipeline.save_review(task)
    shown = %{run | role: lead, task: task, questions: []}

    html = render_component(&UpNext.up_next/1, runs: [shown])

    assert html =~ "Ready for review"
    assert html =~ ~r/data-qa="up-next-action".*>\s*Review\s*</s
    refute html =~ "Ready to merge"

    {:ok, %Run{id: ^run_id}} = Pipeline.start_fix_round(run)
    html = render_component(&UpNext.up_next/1, runs: [shown])

    assert html =~ ~s(href="/tasks/#{task_id}?tab=#{lead.id}")
    assert html =~ "Ready to merge"
    assert html =~ "the pull request is waiting on you to merge it."

    html = render_component(&UpNext.up_next/1, runs: [waiting.(:engineer), shown])

    assert html =~ ~r/id="up-next-row-#{run_id}".*>\s*Ready to merge\s*</s
    assert html =~ ~s(href="/tasks/#{task_id}?tab=#{lead.id}")

    html = render_component(&UpNext.up_next/1, runs: [%{shown | task: %{task | pr_url: nil}}])

    assert html =~ "Ready for review"
    assert html =~ ~s(href="/tasks/#{task_id}")
    refute html =~ "?tab="
  end

  test "a Review round waiting on a person reads Review with the Findings icon, however its findings are ruled", %{
    project: project,
    waiting: waiting
  } do
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    task = learnings_task(project, "UPN-3", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, %Run{id: run_id} = run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    {:ok, %Finding{} = nil_finding} =
      Pipeline.save_finding(task, %{
        key: "unhandled-nil",
        kind: :code,
        raised_by: :code_reviewer,
        title: "Nil is not handled",
        problem: "It crashes.",
        file: "lib/a.ex",
        line: 3,
        fix: "Guard it.",
        why: "It crashes.",
        rule: "Every caller handles nil.",
        severity: :major,
        recommendation: :fix,
        places: [%{file: "lib/a.ex", line: 3}],
        evidence: [%{name: "range", kind: :code, file: "lib/a.ex", line: 3}]
      })

    {:ok, _pass} = Pipeline.save_review(task)
    shown = %{run | role: lead, task: task, questions: []}

    read = fn ->
      doc = (&UpNext.up_next/1) |> render_component(runs: [shown]) |> Floki.parse_fragment!()
      rows = (&UpNext.up_next/1) |> render_component(runs: [waiting.(:engineer), shown]) |> Floki.parse_fragment!()

      %{
        chip: doc |> Floki.find("[data-qa=up-next-chip]") |> Floki.text() |> String.trim(),
        action: doc |> Floki.find("[data-qa=up-next-action]") |> Floki.text() |> String.trim(),
        summary: doc |> Floki.find("[data-qa=up-next-summary]") |> Floki.text() |> String.trim(),
        icons:
          length(Floki.find(doc, "[data-qa=up-next-chip] .pi-list-checks, [data-qa=up-next-action] .pi-list-checks")),
        row: rows |> Floki.find("#up-next-row-#{run_id}") |> Floki.text() |> String.split() |> Enum.join(" ")
      }
    end

    waiting_reading = %{
      chip: "Ready for review",
      action: "Review",
      summary: "Waiting on you to read the findings.",
      icons: 2,
      row: "UPN-3 #{task.issue.title} · findings ready for review Review"
    }

    assert ^waiting_reading = read.()

    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nil_finding, :fix)
    assert ^waiting_reading = read.()

    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), nil_finding, :skip)
    assert ^waiting_reading = read.()
  end

  test "only a Review round waiting on a person carries the Findings icon", %{project: project, waiting: waiting} do
    {:ok, lead} = Roles.get_role(project_id: project.id, stage: :review_lead)
    task = learnings_task(project, "UPN-4", :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    {:ok, task} = Pipeline.update_task(task, %{pr_url: "https://github.com/org/app/pull/14"})

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead.id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_up_next_lead",
        started_at: DateTime.utc_now()
      })

    {:ok, _pass} = Pipeline.save_review(task)
    stopped = %{run | role: lead, task: task, questions: []}

    read = fn shown ->
      doc = (&UpNext.up_next/1) |> render_component(runs: [shown]) |> Floki.parse_fragment!()

      {doc |> Floki.find("[data-qa=up-next-chip]") |> Floki.text() |> String.trim(),
       doc |> Floki.find("[data-qa=up-next-action]") |> Floki.text() |> String.trim(),
       doc |> Floki.find("[data-qa=up-next-summary]") |> Floki.text() |> String.trim(),
       Floki.find(doc, ".pi-list-checks")}
    end

    assert {"Needs a fix", "Fix", "Review lead stopped before finishing. Send it a message to pick up where it left off.",
            []} = read.(%{stopped | role: %{lead | name: "Review lead"}})

    assert {"Needs a fix", "Fix", "The Review lead did not save its review.", []} =
             read.(%{stopped | error: "The Review lead did not save its review."})

    assert {"Needs an answer", "Answer", "Which vendor field?", []} =
             read.(%{
               stopped
               | status: :blocked_on_input,
                 questions: [%Question{status: :pending, prompt: "Which vendor field?"}]
             })

    assert {"Ready for review", "Review", "Waiting on you to read the diff.", []} = read.(waiting.(:engineer))

    {:ok, _finished} = Pipeline.start_fix_round(run)

    assert {"Ready to merge", "Ready to merge", _merge, []} = read.(%{stopped | stage_outcome: :done})
  end

  test "a Plan run with options and no pick asks for the pick, as a card and as a row", %{
    waiting: waiting,
    scratch: scratch
  } do
    options = for key <- ["a", "b", "c"], do: %{"key" => key, "title" => String.upcase(key)}
    File.mkdir_p!(Path.join(scratch, "design"))
    File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))

    html = render_component(&UpNext.up_next/1, runs: [waiting.(:plan)])
    assert html =~ "Waiting on you to pick a design."
    assert html =~ ~r/data-qa="up-next-action".*>\s*Pick\s*</s

    html = render_component(&UpNext.up_next/1, runs: [waiting.(:engineer), waiting.(:plan)])
    assert html =~ ~r/id="up-next-row-run_plan".*pick a design.*>\s*Pick\s*</s
  end
end
