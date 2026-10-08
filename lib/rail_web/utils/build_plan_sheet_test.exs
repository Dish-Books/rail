defmodule RailWeb.Utils.BuildPlanSheetTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers
  import RailWeb.Utils.BuildPlanSheet

  test "every section title, summary line, file entry, module card line and source line is a line" do
    assert %{
             lines: lines,
             summary: %{tally: tally, lines: summary},
             files: [first | _files],
             modules: [action | _modules]
           } =
             build_plan_sheet(sheet_plan())

    assert %{kind: :summary, label: "In this plan, line 1", text: "2 files · 2 modules · 2 diagrams"} = tally

    assert [
             %{tone: :check, line: %{label: "In this plan, line 2", text: "Change diagram and call flow"}},
             %{tone: :check, line: %{label: "In this plan, line 3", text: "Every module in Program design" <> _rest}}
           ] = summary

    assert %{line: %{kind: :file, label: "File 1", text: "lib/rail/pipeline/actions/send_back_to_architect.ex"}} = first

    assert %{
             name_line: %{kind: :module, text: "Rail.Pipeline.Actions.SendBackToArchitect"},
             path_line: %{kind: :module, label: "SendBackToArchitect file"},
             signature_lines: [%{kind: :signature, label: "SendBackToArchitect line 1", number: 1}]
           } = action

    labels = Enum.map(lines, & &1.label)

    for label <- [
          "Approach",
          "Approach, paragraph 1",
          "File-level changes",
          "Program design",
          "Verification",
          "Verification, item 1",
          "Assumptions",
          "Assumptions, item 1",
          "Change diagram line 2",
          "Call flow line 5",
          "File 2",
          "Pipeline line 1"
        ] do
      assert label in labels
    end

    assert lines |> Enum.map(& &1.key) |> Enum.uniq() |> length() == length(lines)
  end

  test "a flowchart's nodes, those only linked included, and a sequence diagram's participants come back by id" do
    assert %{
             diagrams: [
               %{nodes: [%{text: "RS", kind: :node, label: "Change diagram node"}, %{text: "P"}, %{text: "SB"}]},
               %{
                 nodes: [
                   %{text: "You", label: "Call flow node", occurrence: 1},
                   %{text: "RS", occurrence: 2},
                   %{text: "SB", occurrence: 2}
                 ]
               }
             ]
           } = build_plan_sheet(sheet_plan())
  end

  test "a flowchart's subgraphs, styles, edge texts and shapes add no node of their own" do
    plan =
      String.replace(sheet_plan(), ~s(  P --> SB["SendBackToArchitect"]:::new\n), """
        P --> SB["SendBackToArchitect"]:::new
        subgraph Stage [The stage]
        X -- writes --> DB[("tasks")]
        A>flag] -.-> B{decide} ==> C & D
        end
        style X fill:#000
      """)

    assert %{diagrams: [%{nodes: nodes} | _call_flow]} = build_plan_sheet(plan)
    assert Enum.map(nodes, & &1.text) == ["RS", "P", "SB", "X", "DB", "A", "B", "C", "D"]
  end

  test "a plan that does not lay out has no sheet" do
    assert build_plan_sheet("## Implementation plan\n\nJust prose.") == nil
  end
end
