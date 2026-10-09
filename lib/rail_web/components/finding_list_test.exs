defmodule RailWeb.Components.FindingListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote

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
      (&RailWeb.Components.FindingList.finding_list/1)
      |> render_component(findings: findings, running: false, tally: "3 findings", target: nil)
      |> Floki.parse_fragment!()

    assert ["Suppressed", "Fix", "Fix · still failing"] =
             doc |> Floki.find("[data-qa=review_finding_state]") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

    assert [["bg-slate-300", "dark:bg-slate-600"], ["bg-amber-400"], ["bg-slate-400"]] =
             doc
             |> Floki.find("[data-qa=review_finding] > span:first-child")
             |> Enum.map(&(&1 |> Floki.attribute("class") |> hd() |> String.split() |> Enum.drop(4)))
  end
end
