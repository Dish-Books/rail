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
end
