defmodule RailWeb.Utils.BuildTicketLinesTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.BuildTicketLines

  test "the title, priority and estimate are lines carrying their labels" do
    lines = build_ticket_lines(%{title: "Previews", priority: :high, estimate: 3, description: "Body."})

    assert %{
             title: %{kind: :title, text: "Previews", label: "Title"},
             priority: %{kind: :priority, text: "High", label: "Priority"},
             estimate: %{kind: :estimate, text: "3 Points", label: "Estimate"}
           } = lines
  end

  test "a missing priority and estimate read as such, and one point is singular" do
    assert %{priority: %{text: "No priority"}, estimate: %{text: "No estimate"}} =
             build_ticket_lines(%{title: "T", priority: nil, estimate: nil, description: nil})

    assert %{estimate: %{text: "1 Point"}} =
             build_ticket_lines(%{title: "T", priority: nil, estimate: 1, description: ""})
  end

  test "the description becomes its blocks" do
    assert %{
             description: [%{kind: :paragraph, text: "The problem."}, %{kind: :heading}, %{kind: :list_item, text: "One"}]
           } =
             build_ticket_lines(%{
               title: "T",
               priority: nil,
               estimate: nil,
               description: "The problem.\n\n## Acceptance criteria\n\n- One\n"
             })
  end
end
