defmodule RailWeb.Utils.BuildFixPlanLinesTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.BuildFixPlanLines

  alias Rail.Pipeline.Schemas.FixPlan

  setup do
    plan =
      "Guard nil.\n\n### Changes to the plan\n\n- Criterion 1: a dot.\n\nGuard nil.\n\n### What changes\n\n" <>
        "#### `nil-crash`\n\nGuard nil.\n\n#### Comment 1\n\nKept.\n\n```elixir\nx = 1\n```\n\n" <>
        "### File-level changes\n\n- `lib/a.ex`: guards nil. For `nil-crash`.\n- `lib/b.ex`: Guard nil.\n\n" <>
        "### Verification\n\n- Guard nil.\n"

    fix_plan = %FixPlan{
      round: 1,
      plan: plan,
      covered_keys: ["nil-crash"],
      covered_titles: %{"nil-crash" => "Nil crashes the page"},
      comments: [%FixPlan.Comment{number: 1, kind: :diff, text: "Keep it."}],
      covered_comments: 1
    }

    %{sheet: FixPlan.build_sheet(fix_plan)}
  end

  test "each part's lines sit beside it, labelled by the part they are in", %{sheet: sheet} do
    assert %{
             changes_lines: [
               %{kind: :list_item, label: "Changes to the plan, item 1", text: "Criterion 1: a dot."},
               %{kind: :paragraph, label: "Changes to the plan, paragraph 1", text: "Guard nil."}
             ],
             summary_lines: [%{kind: :paragraph, label: "Summary, paragraph 1", text: "Guard nil."}],
             items: [
               %{key: "nil-crash", body_lines: [%{label: "Fix finding nil-crash, paragraph 1", text: "Guard nil."}]},
               %{
                 number: 1,
                 body_lines: [
                   %{kind: :paragraph, label: "Comment 1, paragraph 1", text: "Kept."},
                   %{kind: :code, label: "Comment 1, code line 1", text: "x = 1"}
                 ]
               }
             ],
             files: [
               %{
                 path_line: %{kind: :file, label: "File 1", text: "lib/a.ex"},
                 description_lines: [%{label: "File 1, paragraph 1", text: "guards nil. For nil-crash."}]
               },
               %{
                 path_line: %{kind: :file, label: "File 2", text: "lib/b.ex"},
                 description_lines: [%{label: "File 2, paragraph 1", text: "Guard nil."}]
               }
             ],
             verification_lines: [%{kind: :list_item, label: "Verification, item 1", text: "Guard nil."}]
           } = build_fix_plan_lines(sheet)
  end

  test "lines that read the same are numbered across the whole sheet in reading order, by kind, each with a key of its own",
       %{
         sheet: sheet
       } do
    %{lines: lines} = build_fix_plan_lines(sheet)

    assert [
             {"Changes to the plan, paragraph 1", 1},
             {"Summary, paragraph 1", 2},
             {"Fix finding nil-crash, paragraph 1", 3},
             {"File 2, paragraph 1", 4}
           ] =
             lines
             |> Enum.filter(&(&1.kind == :paragraph and &1.text == "Guard nil."))
             |> Enum.map(&{&1.label, &1.occurrence})

    assert %{occurrence: 1} = Enum.find(lines, &(&1.kind == :list_item and &1.text == "Guard nil."))
    assert lines |> Enum.map(& &1.key) |> Enum.uniq() |> length() == length(lines)
    assert Enum.all?(lines, &String.starts_with?(&1.key, "#{&1.kind}-"))
  end

  test "lines run in reading order: changes, summary, each item, each file's path then description, Verification", %{
    sheet: sheet
  } do
    built = build_fix_plan_lines(sheet)

    assert Enum.map(built.lines, & &1.label) == [
             "Changes to the plan, item 1",
             "Changes to the plan, paragraph 1",
             "Summary, paragraph 1",
             "Fix finding nil-crash, paragraph 1",
             "Comment 1, paragraph 1",
             "Comment 1, code line 1",
             "File 1",
             "File 1, paragraph 1",
             "File 2",
             "File 2, paragraph 1",
             "Verification, item 1"
           ]

    assert built.lines ==
             built.changes_lines ++
               built.summary_lines ++
               Enum.flat_map(built.items, & &1.body_lines) ++
               Enum.flat_map(built.files, &[&1.path_line | &1.description_lines]) ++ built.verification_lines
  end

  test "the same text reads the same key on every build, so a comment finds its line again", %{sheet: sheet} do
    assert Enum.map(build_fix_plan_lines(sheet).lines, & &1.key) == Enum.map(build_fix_plan_lines(sheet).lines, & &1.key)
  end

  test "a plan with no changes, summary, files or Verification has no lines for them" do
    sheet = FixPlan.build_sheet(%FixPlan{round: 1, plan: "### What changes\n\n#### Comment 1\n\nAnswered."})

    assert %{changes_lines: [], summary_lines: [], files: [], verification_lines: [], lines: [], items: []} =
             build_fix_plan_lines(sheet)

    sheet =
      FixPlan.build_sheet(%FixPlan{
        round: 1,
        plan: "### What changes\n\n#### Comment 1\n\nAnswered.",
        comments: [%FixPlan.Comment{number: 1, kind: :screen, text: "Why?"}],
        covered_comments: 1
      })

    assert %{lines: [%{label: "Comment 1, paragraph 1", text: "Answered.", occurrence: 1}]} = build_fix_plan_lines(sheet)
  end
end
