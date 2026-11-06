defmodule Rail.Issues.Utils.FormatLinearIssueTest do
  use ExUnit.Case, async: true

  import Rail.Issues.Utils.FormatLinearIssue

  test "reads an issue into Rail's attributes" do
    assert %{
             external_id: "lin_iss_1",
             identifier: "ENG-1",
             title: "Title",
             description: "Body",
             priority: :urgent,
             estimate: 3,
             state: :done,
             state_name: "Done",
             branch_name: "eng-1",
             url: "https://linear.app/issue/ENG-1"
           } =
             format_linear_issue(%{
               "id" => "lin_iss_1",
               "identifier" => "ENG-1",
               "title" => "Title",
               "description" => "Body",
               "priority" => 1,
               "estimate" => 3,
               "state" => %{"name" => "Done", "type" => "completed"},
               "branchName" => "eng-1",
               "url" => "https://linear.app/issue/ENG-1"
             })
  end

  test "reads when the issue was completed, and nothing for an open or unreadable one" do
    assert %{completed_at: ~U[2026-09-01 12:30:00Z]} =
             format_linear_issue(%{"completedAt" => "2026-09-01T12:30:00.000Z"})

    assert %{completed_at: nil} = format_linear_issue(%{"completedAt" => nil})
    assert %{completed_at: nil} = format_linear_issue(%{"completedAt" => "not a time"})
  end

  test "reads when Linear last changed the issue, to the microsecond the column holds" do
    assert %{external_updated_at: ~U[2026-09-01 12:30:00.250000Z]} =
             format_linear_issue(%{"updatedAt" => "2026-09-01T12:30:00.250Z"})

    assert %{external_updated_at: nil} = format_linear_issue(%{})
    assert %{external_updated_at: nil} = format_linear_issue(%{"updatedAt" => "not a time"})
  end

  test "names Linear's priority numbers, with no priority as medium" do
    assert Enum.map([1, 2, 3, 4, 0, nil], &format_linear_issue(%{"priority" => &1}).priority) ==
             [:urgent, :high, :medium, :low, :medium, :medium]
  end

  test "maps Linear's state types, with anything else as backlog" do
    types = ["triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate", "weird"]

    assert Enum.map(types, &format_linear_issue(%{"state" => %{"type" => &1}}).state) ==
             [:triage, :backlog, :backlog, :in_progress, :done, :canceled, :duplicate, :backlog]

    assert %{state: :backlog, state_name: nil} = format_linear_issue(%{})
  end

  test "reads the cycle and the parent as the API nests them or a webhook flattens them, and nothing when it says nothing" do
    assert %{cycle_external_id: "cyc_1", parent_external_id: "lin_p"} =
             format_linear_issue(%{"cycle" => %{"id" => "cyc_1"}, "parent" => %{"id" => "lin_p"}})

    assert %{cycle_external_id: nil, parent_external_id: nil} = format_linear_issue(%{"cycle" => nil, "parent" => nil})

    assert %{cycle_external_id: "cyc_2", parent_external_id: "lin_q"} =
             format_linear_issue(%{"cycleId" => "cyc_2", "parentId" => "lin_q"})

    assert %{cycle_external_id: nil, parent_external_id: nil} =
             format_linear_issue(%{"cycleId" => nil, "parentId" => nil})

    attrs = format_linear_issue(%{"id" => "lin_1"})
    refute Map.has_key?(attrs, :cycle_external_id)
    refute Map.has_key?(attrs, :parent_external_id)
  end
end
