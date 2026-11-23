defmodule RailWeb.Components.IssueRelationListTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Issues.Schemas.Issue
  alias RailWeb.Components.IssueRelationList

  test "a row in the project links to its page, a finished one dims, and one elsewhere opens at its own address unnamed" do
    entries = [
      %{
        issue: %Issue{identifier: "TST-1", title: "Open one", state: :in_review},
        in_project: true
      },
      %{issue: %Issue{identifier: "TST-2", title: "Done one", state: :done}, in_project: true},
      %{
        issue: %Issue{
          identifier: "OTH-3",
          title: nil,
          state: :todo,
          url: "https://rail.test/issues/iss_oth3"
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
    assert html =~ ~s(href="https://rail.test/issues/iss_oth3")
    assert html =~ "In another project"
    assert html =~ "Todo"
  end

  test "a removable row links its identifier and title, with a button naming it that removes the relation" do
    entries = [
      %{
        issue: %Issue{id: "iss_blocker", identifier: "TST-1", title: "Goes first", state: :todo},
        in_project: true,
        remove: %{blocker_id: "iss_blocker", blocked_id: "iss_page"}
      }
    ]

    html =
      render_component(&IssueRelationList.issue_relation_list/1,
        id: "issue-blocked-by",
        title: "Blocked by",
        count: "1",
        entries: entries,
        blocked: true,
        removable: true
      )

    assert html =~ ~s(id="issue-blocked-by-TST-1-link")
    assert html =~ ~s(href="/issues/TST-1")
    assert html =~ ~s(aria-label="Remove TST-1")
    assert html =~ ~s(phx-click="remove_relation")
    assert html =~ ~s(phx-value-blocker_id="iss_blocker")
    assert html =~ ~s(phx-value-blocked_id="iss_page")
    # The button cannot sit inside the link.
    refute html =~ ~r/<a[^>]*>(?:(?!<\/a>).)*Remove TST-1/s
  end
end
