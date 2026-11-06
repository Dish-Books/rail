defmodule RailWeb.Utils.BuildFixPlanLinesTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.BuildFixPlanLines

  alias Rail.Pipeline.Schemas.FixPlan

  setup do
    plan =
      "Guard nil.\n\n### Changes to the plan\n\n- Criterion 1: a dot.\n\nGuard nil.\n\n### What changes\n\n" <>
        "#### `nil-crash`\n\nGuard nil.\n\n#### Comment 1\n\nKept.\n\n```elixir\nx = 1\n```\n\n" <>
        "### File-level changes\n\n#### `lib/b.ex`\n\nGuard nil.\n\n#### `lib/rail/a.ex`\n\nGuards nil. For `nil-crash`.\n\n" <>
        "```elixir sketch\ndef a(nil), do: :error\n```\n\n#### `lib/c.ex`\n\nAlso. For `nil-crash`.\n\n" <>
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
             files_title: %{kind: :section_title, label: "File-level changes", text: "File-level changes"},
             cards: [
               %{
                 line: %{kind: :file, label: "File 1", text: "lib/b.ex"},
                 prose: [%{label: "File 1, paragraph 1", text: "Guard nil."}],
                 sketch: []
               },
               %{line: %{kind: :file, label: "File 2", text: "lib/c.ex"}},
               %{
                 line: %{kind: :file, label: "File 3", text: "lib/rail/a.ex"},
                 prose: [%{label: "File 3, paragraph 1", text: "Guards nil. For nil-crash."}],
                 sketch: [%{kind: :code, label: "File 3, sketch line 1", text: "def a(nil), do: :error"}]
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
             {"File 1, paragraph 1", 4}
           ] =
             lines
             |> Enum.filter(&(&1.kind == :paragraph and &1.text == "Guard nil."))
             |> Enum.map(&{&1.label, &1.occurrence})

    assert %{occurrence: 1} = Enum.find(lines, &(&1.kind == :list_item and &1.text == "Guard nil."))
    assert lines |> Enum.map(& &1.key) |> Enum.uniq() |> length() == length(lines)
    assert Enum.all?(lines, &String.starts_with?(&1.key, "#{&1.kind}-"))
  end

  test "lines run in reading order: changes, summary, each item, each file's card in drawn order, Verification", %{
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
             "File-level changes",
             "File 1",
             "File 1, paragraph 1",
             "File 2",
             "File 2, paragraph 1",
             "File 3",
             "File 3, paragraph 1",
             "File 3, sketch line 1",
             "Verification, item 1"
           ]

    assert built.lines ==
             built.changes_lines ++
               built.summary_lines ++
               Enum.flat_map(built.items, & &1.body_lines) ++
               [built.files_title | Enum.flat_map(built.cards, &([&1.line] ++ &1.prose ++ &1.signatures ++ &1.sketch))] ++
               built.verification_lines
  end

  test "cards group by where the code goes, numbered as drawn, and each item names its cards by number", %{sheet: sheet} do
    assert %{
             groups: [
               %{name: "lib", cards: [%{path: "lib/b.ex"}, %{path: "lib/c.ex"}]},
               %{name: "a", cards: [%{path: "lib/rail/a.ex"}]}
             ],
             items: [
               %{key: "nil-crash", files: [%{number: 3, path: "lib/rail/a.ex"}, %{number: 2, path: "lib/c.ex"}]},
               %{number: 1, files: []}
             ]
           } = build_fix_plan_lines(sheet)
  end

  test "a card's digest starts with its round, so a mark holds for its own round's card alone", %{sheet: sheet} do
    %{cards: [card | _rest]} = build_fix_plan_lines(sheet)
    %{cards: [next | _rest]} = build_fix_plan_lines(%{sheet | round: 2})

    assert String.starts_with?(card.digest, "1-")
    assert next.digest == "2-" <> String.trim_leading(card.digest, "1-")
  end

  test "the same text reads the same key on every build, so a comment finds its line again", %{sheet: sheet} do
    assert Enum.map(build_fix_plan_lines(sheet).lines, & &1.key) == Enum.map(build_fix_plan_lines(sheet).lines, & &1.key)
  end

  test "a plan with no changes, summary, files or Verification has no lines for them" do
    sheet = FixPlan.build_sheet(%FixPlan{round: 1, plan: "### What changes\n\n#### Comment 1\n\nAnswered."})

    assert %{changes_lines: [], summary_lines: [], cards: [], verification_lines: [], lines: [], items: []} =
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
