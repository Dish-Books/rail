defmodule RailWeb.Utils.BuildPlanSheetTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers
  import RailWeb.Utils.BuildPlanSheet

  test "a full plan yields both diagrams with their source exactly as fenced" do
    change = """
    flowchart LR
      RS["ReviewStage"]:::changed --> P["Pipeline"]:::changed
      P --> SB["SendBackToArchitect"]:::new
      classDef new fill:#052e16,stroke:#34d399,stroke-width:1.5px,stroke-dasharray:5 3,color:#d1fae5
      classDef changed fill:#172554,stroke:#60a5fa,stroke-width:1.5px,color:#dbeafe
    """

    assert %{
             approach: approach,
             no_diagrams: nil,
             diagrams: [
               %{kind: :change, type_label: "Flowchart", caption: "Flowchart", source: ^change},
               %{
                 kind: :call_flow,
                 type_label: "Sequence diagram",
                 caption: "From the Send back button to the tasks and runs tables",
                 source: call_flow
               }
             ]
           } = build_plan_sheet(sheet_plan())

    assert approach =~ "Sending a task back is a stage move"
    refute approach =~ "Implementation plan"

    assert call_flow =~ ~s(sequenceDiagram\n  actor You\n)
    assert call_flow =~ "RS->>SB: send_back_to_architect(run, note)\n"
  end

  test "each file comes out with its path, and each module with its name, path and whether it is new" do
    action_signature = "```elixir\ndef send_back_to_architect(%Run{} = run, note)\n```"

    assert %{
             files: [
               %{path: "lib/rail/pipeline/actions/send_back_to_architect.ex", description: new_action},
               %{path: "lib/rail/pipeline.ex", description: delegate}
             ],
             modules: [
               %{
                 name: "Rail.Pipeline.Actions.SendBackToArchitect",
                 new?: true,
                 path: "lib/rail/pipeline/actions/send_back_to_architect.ex",
                 listed?: true,
                 signatures: ^action_signature
               },
               %{name: "Rail.Pipeline", new?: false, path: "lib/rail/pipeline.ex", listed?: true}
             ],
             verification: verification,
             assumptions: assumptions,
             rest: []
           } = build_plan_sheet(sheet_plan())

    assert String.starts_with?(new_action, "New action. Refuses unless the task is at `:review`")
    assert String.starts_with?(delegate, "Delegates `send_back_to_architect/2`")
    assert verification =~ "`lib/rail/pipeline/actions/send_back_to_architect_test.exs` pins"
    assert assumptions =~ "The note is required"
  end

  test "a file named with nothing after it has no description, and a caption wrapped over lines reads as one" do
    plan =
      sheet_plan()
      |> String.replace(
        "`lib/rail/pipeline.ex`: Delegates `send_back_to_architect/2` beside `send_to_qa/1`.",
        "`lib/rail/pipeline.ex`"
      )
      |> String.replace("From the Send back button to the tasks", "From the Send back button\nto the tasks")

    assert %{
             files: [_action, %{path: "lib/rail/pipeline.ex", description: ""}],
             diagrams: [_change, %{caption: "From the Send back button to the tasks and runs tables"}]
           } = build_plan_sheet(plan)
  end

  test "a module whose file is not in File-level changes is marked unlisted" do
    plan =
      String.replace(sheet_plan(), "### Verification", """
      #### `Rail.Pipeline.Actions.EnterStage`

      `lib/rail/pipeline/actions/enter_stage.ex`

      ```elixir
      def enter_stage(%Task{} = task, stage, opts \\\\ [])
      ```

      ### Verification
      """)

    assert %{modules: [%{listed?: true}, %{listed?: true}, %{name: "Rail.Pipeline.Actions.EnterStage", listed?: false}]} =
             build_plan_sheet(plan)
  end

  test "a plan with no diagrams keeps the line saying why, and no Program design means no modules" do
    plan = """
    ## Implementation plan

    ### Approach

    The missing-worktree case in `Rail.Pipeline.Actions.CleanupTask` already returns `:ok`.

    No diagrams: this plan only adds tests, so no application code or call path changes.

    ### File-level changes

    - `lib/rail/pipeline/actions/cleanup_task_test.exs`: adds a case for a task whose worktree was already deleted.

    ### Verification

    - Run `mix test`.
    """

    assert %{
             approach: approach,
             no_diagrams: "No diagrams: this plan only adds tests, so no application code or call path changes.",
             diagrams: [],
             modules: [],
             files: [%{path: "lib/rail/pipeline/actions/cleanup_task_test.exs"}],
             assumptions: nil
           } = build_plan_sheet(plan)

    refute approach =~ "No diagrams"
  end

  test "a Mermaid block outside the diagram sections stays markdown" do
    plan =
      String.replace(sheet_plan(), "### Assumptions", """
      ```mermaid
      flowchart LR
        A --> B
      ```

      ### Assumptions
      """)

    assert %{diagrams: [%{kind: :change}, %{kind: :call_flow}], verification: verification} = build_plan_sheet(plan)
    assert verification =~ "```mermaid\nflowchart LR\n  A --> B\n```"
  end

  test "a diagram section with no Mermaid block is kept as an ordinary section" do
    plan =
      String.replace(sheet_plan(), ~r/### Call flow\n.*?```\n/s, "### Call flow\n\nIt is one function call.\n")

    assert %{diagrams: [%{kind: :change}], rest: [%{title: "Call flow", body: "It is one function call."}]} =
             build_plan_sheet(plan)
  end

  test "a section the sheet does not know is kept, in order, under its own title" do
    plan =
      sheet_plan()
      |> String.replace("### Verification", "### Rollout\n\nShip it behind nothing.\n\n### Verification")
      |> String.replace("### Assumptions", "### Risks\n\n| risk | odds |\n|---|---|\n| none | low |\n\n### Assumptions")

    assert %{rest: [%{title: "Rollout", body: "Ship it behind nothing."}, %{title: "Risks", body: risks}]} =
             build_plan_sheet(plan)

    assert risks =~ "| risk | odds |"
  end

  test "a plan without the sections the sheet needs is not a sheet" do
    assert build_plan_sheet("## Implementation plan\n\n### Approach\nExtend the invoices module.\n") == nil
    assert build_plan_sheet("## Implementation plan\n\n### File-level changes\n\n- `lib/a.ex`: a.\n") == nil
    assert build_plan_sheet("Just prose, no sections at all.") == nil
  end

  # The old prompt's three sections carry nothing that says whether code changes, so
  # the sheet's summary would be guessing.
  test "a plan in the old three-section format is not a sheet" do
    plan = """
    ## Implementation plan

    ### Approach

    Extend `Rail.Invoices` with a vendor filter.

    ### File-level changes

    - `lib/rail/invoices/actions/list_invoices.ex`: filters by `vendor_id` when given.
    - `lib/rail_web/live/invoices_live.ex`: adds the vendor picker.

    ### Verification

    - `lib/rail/invoices/actions/list_invoices_test.exs` pins the filter.

    ### Assumptions

    - An empty vendor means every vendor.
    """

    assert build_plan_sheet(plan) == nil
  end

  test "an empty Program design is still the new format, with no modules" do
    plan =
      sheet_plan()
      |> String.replace(~r/### Change diagram.*?### File-level changes/s, "### File-level changes")
      |> String.replace(~r/### Program design.*?### Verification/s, "### Program design\n\n### Verification")

    assert %{diagrams: [], no_diagrams: nil, modules: []} = sheet = build_plan_sheet(plan)
    refute Map.has_key?(sheet, :program_design?)
  end

  test "File-level changes that are not a list of files is not a sheet" do
    plan = String.replace(sheet_plan(), "### File-level changes\n", "### File-level changes\n\nTwo files change.\n")

    assert build_plan_sheet(plan) == nil

    plan = String.replace(sheet_plan(), "- `lib/rail/pipeline.ex`: Delegates", "- The context module delegates")

    assert build_plan_sheet(plan) == nil
  end

  # A checkbox is state the sheet has no place for, so the plan keeps it as markdown.
  test "File-level changes written as a task list is not a sheet" do
    plan =
      sheet_plan()
      |> String.replace(
        "- `lib/rail/pipeline/actions/send_back_to_architect.ex`:",
        "- [ ] `lib/rail/pipeline/actions/send_back_to_architect.ex`:"
      )
      |> String.replace("- `lib/rail/pipeline.ex`:", "- [x] `lib/rail/pipeline.ex`:")

    assert build_plan_sheet(plan) == nil
  end

  test "a Program design module is named by its heading even without a code span" do
    plan = String.replace(sheet_plan(), "#### `Rail.Pipeline`\n", "#### The context module\n")

    assert %{modules: [_action, %{name: "The context module", new?: false, path: "lib/rail/pipeline.ex"}]} =
             build_plan_sheet(plan)
  end

  test "a module that names no file is unlisted" do
    plan = String.replace(sheet_plan(), "`lib/rail/pipeline.ex`\n\n```elixir", "```elixir")

    assert %{modules: [_action, %{name: "Rail.Pipeline", path: nil, listed?: false}]} = build_plan_sheet(plan)
  end

  test "a Program design that is not one heading per module is not a sheet" do
    plan = String.replace(sheet_plan(), "### Program design\n", "### Program design\n\nTwo modules change.\n")

    assert build_plan_sheet(plan) == nil
  end

  test "anything written above the first section is kept, without a title" do
    plan = String.replace(sheet_plan(), "### Approach", "A note before the plan.\n\n### Approach")

    assert %{rest: [%{title: nil, body: "A note before the plan."}]} = build_plan_sheet(plan)
  end

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
end
