defmodule RailWeb.Components.FindingIssueTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingPlace
  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Components.FindingIssue

  test "before a Send it shows the issue as Send files it: project, Triage, priority, title and description" do
    preview = %{
      title: "Issues page re-sorts after every sync",
      description: "**Problem.** The sort resets.\n\n**Where.** `lib/a.ex:214`",
      priority: :low
    }

    doc =
      (&FindingIssue.finding_issue/1)
      |> render_component(finding: %Finding{decision: :new_issue}, preview: preview, project_name: "Rail")
      |> Floki.parse_fragment!()

    assert ["The issue Send files"] = doc |> Floki.find("section") |> Floki.attribute("aria-label")
    text = Floki.text(doc)
    assert text =~ ~r/Filed when you send\s+Rail · Triage · Low priority/
    assert doc |> Floki.find("[data-qa=finding_issue_title]") |> Floki.text() =~ "Issues page re-sorts after every sync"

    assert ["Problem."] =
             doc |> Floki.find("[data-qa=finding_issue_description] strong") |> Enum.take(1) |> Enum.map(&Floki.text/1)

    assert doc |> Floki.find("[data-qa=finding_issue_description] code") |> Floki.text() == "lib/a.ex:214"
  end

  test "a finding only recommended New issue says it is filed if someone rules it so" do
    preview = %{title: "Issues page re-sorts", description: "**Problem.** The sort resets.", priority: :low}

    doc =
      (&FindingIssue.finding_issue/1)
      |> render_component(finding: %Finding{recommendation: :new_issue}, preview: preview, project_name: "Rail")
      |> Floki.parse_fragment!()

    assert ["The issue a New issue ruling files"] = doc |> Floki.find("section") |> Floki.attribute("aria-label")
    assert Floki.text(doc) =~ ~r/Filed if you rule New issue\s+Rail · Triage · Low priority/
    refute Floki.text(doc) =~ "Filed when you send"
  end

  test "a filed issue's places read as a numbered list, each path as code, as Linear will show them" do
    finding = %Finding{
      decision: :new_issue,
      kind: :code,
      problem: "The sort resets.",
      file: "lib/rail_web/live/issues_live.ex",
      line: 214,
      fix: "Reload with the sort in the filters.",
      why: "It predates this branch.",
      severity: :minor,
      places: [
        %FindingPlace{file: "lib/rail_web/live/issues_live.ex", line: 214, label: "handle_info/2"},
        %FindingPlace{file: "lib/rail/issues/list_issues.ex", line: 9}
      ]
    }

    task = %Task{issue: %Issue{identifier: "RAIL-131", url: "https://linear.app/x/issue/RAIL-131"}}

    doc =
      (&FindingIssue.finding_issue/1)
      |> render_component(finding: finding, preview: Finding.calculate_issue(finding, task), project_name: "Rail")
      |> Floki.parse_fragment!()

    assert [_first, _second] = Floki.find(doc, "[data-qa=finding_issue_description] ol li")

    assert ["lib/rail_web/live/issues_live.ex:214", "lib/rail/issues/list_issues.ex:9"] =
             doc |> Floki.find("[data-qa=finding_issue_description] ol li code") |> Enum.map(&Floki.text/1)
  end

  test "once filed it shows the issue it became, as Rail last synced it, open in its tracker" do
    issue = %Issue{
      identifier: "RAIL-152",
      url: "https://linear.app/x/issue/RAIL-152",
      title: "Issues page re-sorts after every sync",
      state: :todo,
      state_name: "Backlog",
      priority: :high,
      tracker: :linear
    }

    doc =
      (&FindingIssue.finding_issue/1)
      |> render_component(finding: %Finding{decision: :new_issue, issue_id: "iss_1", issue: issue}, project_name: "Rail")
      |> Floki.parse_fragment!()

    text = Floki.text(doc)
    assert text =~ ~r/Filed as\s+RAIL-152\s+· Backlog · High priority/
    assert text =~ "Its ruling can no longer change."
    assert doc |> Floki.find("#finding-issue-open") |> Floki.text() =~ "Open in Linear"
    assert ["https://linear.app/x/issue/RAIL-152"] = doc |> Floki.find("#finding-issue-open") |> Floki.attribute("href")

    doc =
      (&FindingIssue.finding_issue/1)
      |> render_component(
        finding: %Finding{decision: :new_issue, issue_id: "iss_1", issue: %{issue | state_name: nil, tracker: :github}},
        project_name: "Rail"
      )
      |> Floki.parse_fragment!()

    assert Floki.text(doc) =~ "· Todo · High priority"
    assert doc |> Floki.find("#finding-issue-open") |> Floki.text() =~ "Open in GitHub"
  end
end
