defmodule RailWeb.Utils.BuildPlanSheetTest do
  use ExUnit.Case, async: true

  import RailTest.Helpers
  import RailWeb.Utils.BuildPlanSheet

  test "cards fall into groups in the order each first appears, and File N follows the order they are drawn" do
    plan =
      String.replace(sheet_plan(), "### Acceptance criteria", """
      #### `.rail/prompts/plan.md`

      Says so.

      #### `assets/js/app.js`

      Registers nothing new.

      #### `test/support/helpers.ex`

      Helps.

      #### `mix.exs`

      Pins it.

      ### Acceptance criteria
      """)

    assert %{groups: groups, cards: cards} = build_plan_sheet(plan)

    assert [
             {"pipeline", "pipeline", "lib/rail/pipeline",
              [
                "lib/rail/pipeline/actions/send_back_to_architect.ex",
                "lib/rail/pipeline.ex",
                "lib/rail/pipeline/actions/old_send_back.ex"
              ]},
             {"web", "web", "lib/rail_web", ["lib/rail_web/live/review_stage.ex"]},
             {"migrations", "migrations", "priv/repo/migrations", [_migration]},
             {"prompts", "prompts", ".rail/prompts", [".rail/prompts/plan.md"]},
             {"assets", "assets", "assets", ["assets/js/app.js"]},
             {"test", "test", "test", ["test/support/helpers.ex"]},
             {"root", "root", ".", ["mix.exs"]}
           ] = Enum.map(groups, &{&1.name, &1.slug, &1.directory, Enum.map(&1.cards, fn card -> card.path end)})

    assert [
             {1, "lib/rail/pipeline/actions/send_back_to_architect.ex", "File 1"},
             {2, "lib/rail/pipeline.ex", "File 2"},
             {3, "lib/rail/pipeline/actions/old_send_back.ex", "File 3"},
             {4, "lib/rail_web/live/review_stage.ex", "File 4"} | _rest
           ] = Enum.map(cards, &{&1.number, &1.path, &1.line.label})

    assert %{line: %{label: "File 2"}} = groups |> hd() |> Map.fetch!(:cards) |> Enum.at(1)
  end

  test "a card's signatures and sketch are highlighted" do
    def = ~s(<span class="l-keyword-function">def</span> <span class="l-function">send_back_to_architect</span>)

    assert %{
             cards: [
               %{signatures: [%{html: ^def <> _signature}], sketch: [%{html: ^def <> _sketch} | _lines]} | _cards
             ]
           } = build_plan_sheet(sheet_plan())
  end

  test "the lines hold every part in the order it is drawn, the sketch's included, each with a key of its own" do
    assert %{lines: lines} = build_plan_sheet(sheet_plan())

    assert [
             {:section_title, "Approach"},
             {:paragraph, "Approach, paragraph 1"},
             {:section_title, "Data changes"},
             {:list_item, "Data change 1"},
             {:section_title, "Decisions"},
             {:list_item, "Decisions, item 1"},
             {:list_item, "Decisions, item 2"},
             {:list_item, "Decisions, item 3"},
             {:section_title, "Changes"},
             {:file, "File 1"},
             {:paragraph, "File 1, paragraph 1"},
             {:signature, "File 1, signature line 1"},
             {:code, "File 1, sketch line 1"},
             {:code, "File 1, sketch line 2"},
             {:code, "File 1, sketch line 3"},
             {:file, "File 2"},
             {:paragraph, "File 2, paragraph 1"},
             {:signature, "File 2, signature line 1"},
             {:file, "File 3"},
             {:paragraph, "File 3, paragraph 1"},
             {:file, "File 4"},
             {:paragraph, "File 4, paragraph 1"},
             {:file, "File 5"},
             {:paragraph, "File 5, paragraph 1"},
             {:section_title, "Acceptance criteria"},
             {:table_row, "Criterion 1"},
             {:table_row, "Criterion 3"},
             {:section_title, "Verification"},
             {:list_item, "Verification, item 1"}
           ] = Enum.map(lines, &{&1.kind, &1.label})

    assert lines |> Enum.map(& &1.key) |> Enum.uniq() |> length() == length(lines)
  end

  test "a decision and a data change keep their kind beside their own words, and the line reads as the plan does" do
    assert %{
             data_changes: %{
               items: [
                 %{
                   kind: "New column",
                   name: "tasks.sent_back_note",
                   html: "<p>text, null until a task is sent back.</p>",
                   line: %{text: "New column tasks.sent_back_note: text, null until a task is sent back."}
                 }
               ]
             },
             decisions: %{
               items: [
                 %{kind: :decision, html: "<p>the note is kept on the task" <> _decision},
                 %{kind: :ruled_out, line: %{text: "Ruled out: a table of send-backs with their history."}},
                 %{kind: :assumption}
               ]
             }
           } = build_plan_sheet(sheet_plan())
  end

  test "each criterion is a table row of its number, its files and its tests, marked first and last" do
    assert %{criteria: %{rows: [first, last]}} = build_plan_sheet(sheet_plan())

    assert %{
             number: 1,
             line: %{
               kind: :table_row,
               text: "1 | send_back_to_architect.ex | send_back_to_architect_test.exs",
               cells: [
                 "<p>1</p>",
                 "<p><code>send_back_to_architect.ex</code></p>",
                 "<p><code>send_back_to_architect_test.exs</code></p>"
               ],
               columns: 3,
               first?: true,
               last?: false
             }
           } = first

    assert %{number: 3, line: %{text: "3 | review_stage.ex | ", cells: [_number, _files, ""], last?: true}} = last
  end

  test "a criterion of the ticket the plan answers nothing for is an empty row in its numbered place" do
    assert %{criteria: %{rows: [first, second, third]}, lines: lines} = build_plan_sheet(sheet_plan(), [1, 2, 3])

    assert %{number: 1, line: %{first?: true, last?: false}} = first

    assert %{
             number: 2,
             files: [],
             tests: [],
             line: %{
               kind: :table_row,
               label: "Criterion 2",
               text: "2 |  | ",
               cells: ["<p>2</p>", "", ""],
               first?: false,
               last?: false
             }
           } = second

    assert %{number: 3, line: %{last?: true}} = third

    assert ["Criterion 1", "Criterion 2", "Criterion 3"] =
             for(%{kind: :table_row} = line <- lines, do: line.label)
  end

  test "lines that read the same are told apart by the order they are drawn in" do
    plan = String.replace(sheet_plan(), "Adds the column.", "The new action replaces it.")

    assert %{cards: cards} = build_plan_sheet(plan)

    assert [%{occurrence: 1, key: first}, %{occurrence: 2, key: second}] =
             for(card <- cards, line <- card.prose, line.text == "The new action replaces it.", do: line)

    assert first != second
  end

  test "a card's digest moves when its own text changes, and not when another card's does" do
    digests = fn plan -> plan |> build_plan_sheet() |> Map.fetch!(:cards) |> Map.new(&{&1.path, &1.digest}) end
    before = digests.(sheet_plan())

    after_revision =
      sheet_plan()
      |> String.replace("Adds the Send back button beside Send to QA.", "Adds the Send back button under the footer.")
      |> digests.()

    assert before["lib/rail_web/live/review_stage.ex"] != after_revision["lib/rail_web/live/review_stage.ex"]

    assert Map.delete(before, "lib/rail_web/live/review_stage.ex") ==
             Map.delete(after_revision, "lib/rail_web/live/review_stage.ex")

    assert before |> Map.values() |> Enum.uniq() |> length() == map_size(before)
  end

  test "a plan without Data changes, criteria or Verification has no such part, and one that does not lay out has none" do
    plan =
      sheet_plan()
      |> String.replace(~r/### Data changes\n.*?### Decisions/s, "### Decisions")
      |> String.replace(~r/### Acceptance criteria\n.*\z/s, "")

    assert %{data_changes: nil, criteria: nil, verification: nil, lines: lines} = build_plan_sheet(plan)
    refute Enum.any?(lines, &(&1.kind == :table_row))

    assert build_plan_sheet("## Implementation plan\n\nJust prose.") == nil
  end
end
