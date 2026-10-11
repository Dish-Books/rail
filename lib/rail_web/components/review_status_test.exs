defmodule RailWeb.Components.ReviewStatusTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RailWeb.Components.ReviewStatus

  @counts %{fix: 2, fixed: 3, dismissed: 1}

  test "a first round names who is working" do
    explorers = [%{name: "QA explorer 1", work: "Checks 1 and 2", running: true}]
    reviewer = [%{name: "Code reviewer", work: "Read the branch", running: true}]

    for {agents, said} <- [{explorers, "Round 1 · 1 QA explorer working"}, {reviewer, "Round 1 · Code reviewer working"}] do
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

  # A Send of comments alone, or a chat turn on a finished review, works with no finding ruled Fix.
  test "a fix round with nothing ruled Fix says the lead works on what was sent, not that it fixes none" do
    doc =
      (&ReviewStatus.review_status/1)
      |> render_component(phase: :fixing, round: 1, counts: %{@counts | fix: 0})
      |> Floki.parse_fragment!()

    assert "Review lead working on what was sent" =
             doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() =~
             "Nothing is ruled Fix, so no finding is being fixed."
  end

  test "CI with no commit to name says what it runs, and a finish with no pull request names none" do
    ci = render_component(&ReviewStatus.review_status/1, phase: :ci, round: 2, counts: @counts)
    finished = render_component(&ReviewStatus.review_status/1, phase: :finished, round: 2, counts: @counts)

    assert "CI running · Fix round 2" =
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

    assert "CI running on 7c3e91a · Fix round 1" =
             doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert "The next round starts on its own when CI passes." =
             doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim()

    assert [] = Floki.find(doc, "[data-qa=review_status_log]")
  end

  test "CI failed three times sends the reader to the CI output in the conversation, with no log" do
    doc =
      (&ReviewStatus.review_status/1)
      |> render_component(phase: :ci_failed, round: 2, counts: @counts)
      |> Floki.parse_fragment!()

    assert "CI failed 3 times on fix round 2" = doc |> Floki.find("[data-qa=review_status_headline]") |> Floki.text()

    assert "The Review lead stopped. Read the CI output in the conversation, then message the lead. It can run CI again with nothing changed." =
             doc |> Floki.find("[data-qa=review_status_body]") |> Floki.text() |> String.trim()

    assert [] = Floki.find(doc, "[data-qa=review_status_log]")
  end
end
