defmodule RailWeb.Components.FindingListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote
  alias RailWeb.Components.FindingList

  test "each finding's state reads in the list, and its dot quiets once it is settled" do
    findings = [
      %Finding{
        key: "suppressed",
        kind: :code,
        round: 1,
        title: "A",
        file: "a.ex",
        line: 1,
        severity: :major,
        suppressed_by_id: "lrn_1"
      },
      %Finding{key: "minor", kind: :code, round: 1, title: "B", file: "b.ex", line: 2, severity: :minor, decision: :fix},
      %Finding{
        key: "nit",
        kind: :screen,
        round: 1,
        title: "C",
        screen: "Review tab",
        severity: :nit,
        decision: :fix,
        status: :not_fixed,
        notes: [%FindingNote{kind: :pass, status: :not_fixed, commit: nil}]
      }
    ]

    doc =
      (&FindingList.finding_list/1)
      |> render_component(findings: findings, running: false, tally: "3 findings", target: nil)
      |> Floki.parse_fragment!()

    assert ["Suppressed", "Fix", "Fix · still failing"] =
             doc |> Floki.find("[data-qa=review_finding_state]") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

    assert [["bg-slate-300", "dark:bg-slate-600"], ["bg-amber-400"], ["bg-slate-400"]] =
             doc
             |> Floki.find("[data-qa=review_finding] > span:first-child")
             |> Enum.map(&(&1 |> Floki.attribute("class") |> hd() |> String.split() |> Enum.drop(4)))
  end

  test "a finding ruled New issue reads filed on Send until a Send files it, then its identifier, its dot quiet" do
    findings = [
      %Finding{
        key: "resort",
        kind: :code,
        round: 1,
        title: "A",
        file: "a.ex",
        line: 1,
        severity: :blocker,
        decision: :new_issue
      },
      %Finding{
        key: "branch",
        kind: :code,
        round: 1,
        title: "B",
        file: "b.ex",
        line: 2,
        severity: :major,
        decision: :new_issue,
        issue_id: "iss_1",
        issue: %Issue{identifier: "RAIL-152"}
      },
      %Finding{
        key: "tray",
        kind: :code,
        round: 1,
        title: "C",
        file: "c.ex",
        line: 3,
        severity: :major,
        decision: :new_issue
      }
    ]

    doc =
      (&FindingList.finding_list/1)
      |> render_component(findings: findings, running: false, tally: "", changed: %{"tray" => :new_issue}, target: nil)
      |> Floki.parse_fragment!()

    assert ["New issue · filed on Send", "New issue · RAIL-152", "New issue · changed since the plan"] =
             doc |> Floki.find("[data-qa=review_finding_state]") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

    assert [_plus] = Floki.find(doc, "#finding-resort .pi-plus-square-bold")
    assert [_out] = Floki.find(doc, "#finding-branch .pi-arrow-square-out-bold")

    assert [["bg-slate-300", "dark:bg-slate-600"], ["bg-slate-300", "dark:bg-slate-600"] | _changed] =
             doc
             |> Floki.find("[data-qa=review_finding] > span:first-child")
             |> Enum.map(&(&1 |> Floki.attribute("class") |> hd() |> String.split() |> Enum.drop(4)))

    assert [] = Floki.find(doc, "[data-qa=review_finding].opacity-60")
  end

  # Send lives in the conversation's tray, so the footer only counts.
  test "the footer reads the tally and holds no button" do
    doc =
      (&FindingList.finding_list/1)
      |> render_component(findings: [], running: false, tally: "1 to fix · 2 not fixing", target: nil)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#review-finding-footer") |> Floki.text() =~ "1 to fix · 2 not fixing"
    assert [] = Floki.find(doc, "#review-finding-footer button")
  end

  test "a finding whose ruling changed since the fix plan says so in its row" do
    findings = [
      %Finding{key: "count", kind: :screen, round: 1, title: "Count", screen: "Tray", severity: :minor, decision: :skip},
      %Finding{key: "send", kind: :screen, round: 1, title: "Send", screen: "Tray", severity: :major, decision: :fix}
    ]

    doc =
      (&FindingList.finding_list/1)
      |> render_component(findings: findings, running: false, tally: "", changed: %{"count" => :skip}, target: nil)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#finding-count [data-qa=review_finding_state]") |> Floki.text() =~
             "Don't fix · changed since the plan"

    assert doc |> Floki.find("#finding-send [data-qa=review_finding_state]") |> Floki.text() |> String.trim() == "Fix"

    doc =
      (&FindingList.finding_list/1)
      |> render_component(findings: findings, running: false, tally: "", changed: %{"send" => :fix}, target: nil)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#finding-send [data-qa=review_finding_state]") |> Floki.text() =~
             "Fix · changed since the plan"
  end
end
