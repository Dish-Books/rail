defmodule RailWeb.Components.ReviewStatusTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.ReviewStatus

  @counts %{fix: 2, fixed: 3, dismissed: 1}

  test "a first round names who is working" do
    explorers = [%{name: "QA explorer 1", work: "Checks 1 and 2", running: true}]
    reviewer = [%{name: "Code reviewer", work: "Read the branch", running: true}]

    for {agents, said} <- [
          {[], "Round 1 · Starting"},
          {explorers, "Round 1 · QA explorer 1 working"},
          {reviewer, "Round 1 · Code reviewer working"}
        ] do
      html = render_component(&ReviewStatus.review_status/1, phase: :round, round: 1, agents: agents, counts: @counts)

      assert [^said] =
               html
               |> Floki.parse_fragment!()
               |> Floki.find("[data-qa=review_status_headline]")
               |> Enum.map(&Floki.text/1)
    end
  end

  test "a later round with no commit to name re-reviews, and a finished agent shows as done" do
    html =
      render_component(&ReviewStatus.review_status/1,
        phase: :round,
        round: 2,
        agents: [%{name: "Engineer", work: "Fix the 2", running: false}],
        counts: @counts
      )

    doc = Floki.parse_fragment!(html)
    assert "Round 2 · Re-review" = doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()
    assert [_done] = Floki.find(doc, "[data-qa=review_status_agent] .pi-check-circle")
  end

  test "the engineer at work names the round's kind: the first plan, an Update, or what a fix round fixes" do
    said = fn attrs ->
      doc =
        (&ReviewStatus.review_status/1)
        |> render_component([phase: :fixing, counts: @counts] ++ attrs)
        |> Floki.parse_fragment!()

      {doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text(),
       doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim()}
    end

    assert {"Round 1 · Engineer building the plan", "Findings come once the round is reviewed."} =
             said.(round: 1, work: :build)

    assert {"Round 3 · Update · Engineer merging origin/trunk",
            "Brings the branch up to date with trunk, and changes nothing else. Findings can be ruled once the round is back at Review."} =
             said.(round: 3, work: :update, base: "trunk")

    ruled = "Findings can be ruled once the round is back at Review."
    assert {"Round 2 · Engineer fixing 1 finding", ^ruled} = said.(round: 2, work: {:fix, 1, 0})
    assert {"Round 2 · Engineer working on 2 comments", ^ruled} = said.(round: 2, work: {:fix, 0, 2})
    assert {"Round 2 · Engineer fixing 2 findings and 1 comment", ^ruled} = said.(round: 2, work: {:fix, 2, 1})
  end

  test "an engineer waiting on an answer shows the question and the way to its conversation" do
    doc =
      (&ReviewStatus.review_status/1)
      |> render_component(phase: :blocked, round: 3, counts: @counts, question: "CI fails on a test from main.")
      |> Floki.parse_fragment!()

    assert "Round 3 · Engineer waiting on your answer" =
             doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert "CI fails on a test from main." =
             doc |> Floki.find("[data-qa=review_status_detail]") |> Floki.text() |> String.trim()

    assert "Answer it in its conversation. Findings can be ruled once the round is back at Review." =
             doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim()

    assert "Answer the engineer" = doc |> Floki.find("#review-status-open-engineer") |> Floki.text() |> String.trim()
    assert ["engineer"] = doc |> Floki.find("#review-status-open-engineer") |> Floki.attribute("phx-value-stage")
  end

  test "an engineer whose questions are all answered waits on them being sent" do
    doc =
      (&ReviewStatus.review_status/1)
      |> render_component(phase: :blocked, round: 3, counts: @counts)
      |> Floki.parse_fragment!()

    assert "Round 3 · Engineer's answers waiting to be sent" =
             doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert [] = Floki.find(doc, "[data-qa=review_status_detail]")
  end

  test "a failed engineer names its error and Retry, and a stopped one points to its conversation" do
    said = fn attrs ->
      doc =
        (&ReviewStatus.review_status/1)
        |> render_component([phase: :stalled, round: 3, counts: @counts] ++ attrs)
        |> Floki.parse_fragment!()

      {doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text(),
       doc |> Floki.find("[data-qa=review_status_detail]") |> Floki.text() |> String.trim(),
       doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim(),
       doc |> Floki.find("#review-status-open-engineer") |> Floki.text() |> String.trim()}
    end

    assert {"Round 3 · Engineer failed", "Claude exited 1", "Retry the engineer from the header.",
            "Open the engineer's conversation"} = said.(error: "Claude exited 1")

    assert {"Round 3 · Engineer stopped", "",
            "It stopped before finishing the round. Its conversation shows where it got to.",
            "Open the engineer's conversation"} = said.([])
  end

  test "CI with no commit to name says what it runs, and a finish with no pull request names none" do
    ci = render_component(&ReviewStatus.review_status/1, phase: :ci, round: 2, counts: @counts)
    finished = render_component(&ReviewStatus.review_status/1, phase: :finished, round: 2, counts: @counts)

    assert "CI running · Round 2" =
             ci |> Floki.parse_fragment!() |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert "3 findings fixed, 1 not fixing." =
             finished
             |> Floki.parse_fragment!()
             |> Floki.find("[data-qa=review_status_body]")
             |> Floki.text()
             |> String.trim()
  end

  test "CI on the fix commit shows its headline and one line, with no log" do
    doc =
      (&ReviewStatus.review_status/1)
      |> render_component(phase: :ci, round: 1, sha: "7c3e91a", counts: @counts)
      |> Floki.parse_fragment!()

    assert "CI running on 7c3e91a · Round 1" =
             doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert "The round's review starts on its own when CI passes." =
             doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim()

    assert [] = Floki.find(doc, "[data-qa=review_status_log]")
  end

  test "CI failed three times sends the reader to the CI output in the engineer's conversation, with no log" do
    doc =
      (&ReviewStatus.review_status/1)
      |> render_component(phase: :ci_failed, round: 2, counts: @counts)
      |> Floki.parse_fragment!()

    assert "CI failed 3 times on round 2" = doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert "The engineer stopped. Read the CI output in its conversation, then retry the engineer from the header." =
             doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim()

    assert [_open] = Floki.find(doc, "#review-status-open-engineer")

    assert [] = Floki.find(doc, "[data-qa=review_status_log]")
  end

  test "a fix round's plan being written, revised, waiting or out of date names the round" do
    headline = fn attrs ->
      html = render_component(&ReviewStatus.review_status/1, [counts: @counts] ++ attrs)
      doc = Floki.parse_fragment!(html)

      {doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text(),
       doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim(),
       Floki.find(doc, "#review-status-open-fix-plan") != []}
    end

    assert {"Fix round 1 · Review lead writing the fix plan", "Nothing changes until you approve it." <> _rest, false} =
             headline.(phase: :planning, round: 1)

    assert {"Fix round 2 · Review lead writing the fix plan",
            "On 1 changed ruling. Approve comes back when the revised plan is saved.", false} =
             headline.(phase: :planning, round: 2, revising: "1 changed ruling")

    assert {"Fix round 1 · Fix plan waiting on your approval", "Nothing changes until you approve." <> _rest, true} =
             headline.(phase: :waiting, round: 1)

    assert {"Fix round 1 · Fix plan out of date",
            "A ruling changed since the plan was saved. Send the change from the tray for a revised plan, or change it back to approve this one.",
            true} = headline.(phase: :outdated, round: 1)
  end
end
