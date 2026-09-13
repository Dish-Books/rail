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

  test "names Linear's priority numbers, with no priority as medium" do
    assert Enum.map([1, 2, 3, 4, 0, nil], &format_linear_issue(%{"priority" => &1}).priority) ==
             [:urgent, :high, :medium, :low, :medium, :medium]
  end

  test "maps Linear's state types, with anything else as backlog" do
    types = ["triage", "backlog", "unstarted", "started", "completed", "canceled", "weird"]

    assert Enum.map(types, &format_linear_issue(%{"state" => %{"type" => &1}}).state) ==
             [:triage, :backlog, :backlog, :in_progress, :done, :canceled, :backlog]

    assert %{state: :backlog, state_name: nil} = format_linear_issue(%{})
  end
end
