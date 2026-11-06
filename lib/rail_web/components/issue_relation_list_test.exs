defmodule RailWeb.Components.IssueRelationListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias RailWeb.Components.IssueRelationList

  test "a row in the project links to its page, a finished one dims, and one elsewhere opens in Linear unnamed" do
    entries = [
      %{
        issue: %Issue{
          external_id: "lin_1",
          identifier: "TST-1",
          title: "Open one",
          state: :in_progress,
          state_name: "In Review"
        },
        in_project: true
      },
      %{issue: %Issue{external_id: "lin_2", identifier: "TST-2", title: "Done one", state: :done}, in_project: true},
      %{
        issue: %Issue{
          external_id: "lin_3",
          identifier: "OTH-3",
          title: nil,
          state: :todo,
          url: "https://linear.app/OTH-3"
        },
        in_project: false
      }
    ]

    html =
      render_component(&IssueRelationList.issue_relation_list/1,
        id: "issue-blocked-by",
        title: "Blocked by",
        count: "2",
        entries: entries,
        blocked: true
      )

    assert html =~ ~s(id="issue-blocked-by")
    assert html =~ "pi-prohibit-bold"
    assert html =~ ~s(href="/issues/TST-1")
    assert html =~ "In Review"
    assert html =~ "text-emerald-500"
    assert html =~ "Done one"
    assert html =~ "Done"
    assert html =~ ~s(href="https://linear.app/OTH-3")
    assert html =~ "In another project"
    assert html =~ "Todo"
  end
end
