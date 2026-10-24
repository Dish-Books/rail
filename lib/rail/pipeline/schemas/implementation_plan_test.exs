defmodule Rail.Pipeline.Schemas.ImplementationPlanTest do
  use Rail.DataCase, async: true

  import Ecto.Changeset

  alias Rail.Pipeline.Schemas.ImplementationPlan

  # A plan in the sections from before cards, which a saved plan may still be.
  @old_plan """
  ## Implementation plan

  ### Approach

  Extend `Rail.Invoices` with a vendor filter.

  ### Change diagram

  ```mermaid
  flowchart LR
    A --> B
  ```

  ### Call flow

  ```mermaid
  sequenceDiagram
    A->>B: go
  ```

  ### File-level changes

  - `lib/rail/invoices/actions/list_invoices.ex`: filters by `vendor_id` when given.

  ### Program design

  #### `Rail.Invoices`

  `lib/rail/invoices.ex`

  ```elixir
  def list_invoices(scope, filters)
  ```

  ### Verification

  - `lib/rail/invoices/actions/list_invoices_test.exs` pins the filter.
  """

  setup_all do
    %{
      check: fn plan ->
        {%{}, %{plan: :string}} |> cast(%{plan: plan}, [:plan]) |> ImplementationPlan.validate_structure(:plan)
      end
    }
  end

  describe "validate_structure/2" do
    test "accepts a plan in the sections Rail lays out", %{check: check} do
      assert check.(sheet_plan()).valid?
      assert check.(String.replace(sheet_plan(), ~r/### Data changes\n.*?### Decisions/s, "### Decisions")).valid?
    end

    test "refuses a plan with diagrams, File-level changes or Program design, naming the sections it needs", %{
      check: check
    } do
      assert %{plan: errors} = errors_on(check.(@old_plan))

      assert ("has a `### Change diagram` section, but the sections are `### Approach`, `### Data changes`, " <>
                "`### Decisions`, `### Changes`, `### Acceptance criteria`, `### Verification`, with exactly these titles") in errors

      assert Enum.any?(errors, &(&1 =~ "has a `### File-level changes` section"))
      assert Enum.any?(errors, &(&1 =~ "has a `### Program design` section"))
      assert "is missing its `### Changes` section" in errors
      assert "is missing its `### Decisions` section" in errors
    end

    test "refuses sections out of order, twice over, or with text above them", %{check: check} do
      swapped =
        sheet_plan()
        |> String.replace("### Decisions", "### Swap")
        |> String.replace("### Data changes", "### Decisions")
        |> String.replace("### Swap", "### Data changes")

      assert %{plan: ["has its sections out of order; they go `### Approach`" <> _rest | _bodies]} =
               errors_on(check.(swapped))

      twice = sheet_plan() <> "\n### Verification\n\n- Again.\n"
      assert %{plan: ["has `### Verification` more than once"]} = errors_on(check.(twice))

      lead = String.replace(sheet_plan(), "### Approach", "A note first.\n\n### Approach")
      assert %{plan: ["has text between `## Implementation plan` and `### Approach`" <> _rest]} = errors_on(check.(lead))
    end

    test "refuses a decision not led by its kind, and a data change with no name in backticks", %{check: check} do
      plan = String.replace(sheet_plan(), "- Assumption: the note", "- We assume the note")

      assert %{plan: ["has a line under `### Decisions` that is not a bullet starting `Decision:`" <> _rest]} =
               errors_on(check.(plan))

      plan = String.replace(sheet_plan(), "- New column `tasks.sent_back_note`:", "- New column tasks.sent_back_note:")

      assert %{plan: ["has a line under `### Data changes` that is not a bullet giving the change's kind" <> _rest]} =
               errors_on(check.(plan))

      plan = String.replace(sheet_plan(), "- Ruled out: a table", "- Ruled out: a table\n  - of send-backs")
      assert %{plan: ["has sub-bullets under `### Decisions`; it is one flat bullet per item"]} = errors_on(check.(plan))

      plan = String.replace(sheet_plan(), ~r/(### Decisions\n\n).*?(\n### Changes)/s, "\\1\\2")
      assert %{plan: ["has nothing under `### Decisions`" <> _rest]} = errors_on(check.(plan))
    end

    test "refuses a criteria bullet with no number, a number used twice, or naming no path", %{check: check} do
      plan =
        String.replace(sheet_plan(), "- 3: `lib/rail_web/live/review_stage.ex`", "- `lib/rail_web/live/review_stage.ex`")

      assert %{
               plan: ["has a line under `### Acceptance criteria` that is not a bullet starting with the number" <> _rest]
             } =
               errors_on(check.(plan))

      plan = String.replace(sheet_plan(), "- 3: `lib/rail_web", "- 1: `lib/rail_web")

      assert %{plan: ["has criterion 1 more than once under `### Acceptance criteria`; give each criterion one bullet"]} =
               errors_on(check.(plan))

      plan = String.replace(sheet_plan(), "- 3: `lib/rail_web", "- 2: handled by the existing flow\n- 3: `lib/rail_web")

      assert %{
               plan: [
                 "has criterion 2 under `### Acceptance criteria` with no file or test in backticks; name what " <>
                   "satisfies it, or leave the criterion out so it reads Not covered"
               ]
             } = errors_on(check.(plan))
    end

    test "refuses a card that names no path, a path listed twice, or two sketches on one card", %{check: check} do
      plan = String.replace(sheet_plan(), "#### `lib/rail_web/live/review_stage.ex`", "#### The review stage")

      assert %{plan: ["has a heading under `### Changes` that is not `#### `path/to/file``" <> _rest]} =
               errors_on(check.(plan))

      plan = String.replace(sheet_plan(), "#### `lib/rail_web/live/review_stage.ex`", "#### `lib/rail/pipeline.ex`")

      assert %{plan: ["lists `lib/rail/pipeline.ex` more than once under `### Changes`; give each file one card"]} =
               errors_on(check.(plan))

      plan = String.replace(sheet_plan(), "### Changes\n", "### Changes\n\nFive files.\n")

      assert %{plan: ["needs `### Changes` to be a `#### `path/to/file`` card for each file" <> _rest]} =
               errors_on(check.(plan))

      plan =
        String.replace(
          sheet_plan(),
          "Adds the column.\n",
          "Adds the column.\n\n```sql sketch\nA\n```\n\n```sketch\nB\n```\n"
        )

      assert %{plan: ["has more than one code block of a kind under `#### `priv/repo/migrations/" <> _rest]} =
               errors_on(check.(plan))
    end

    test "refuses what passes the line checks but does not lay out, such as code among the decisions", %{
      check: check
    } do
      plan =
        String.replace(
          sheet_plan(),
          "- Assumption: the note is required.\n",
          "- Assumption: the note is required.\n\n```\nnote\n```\n"
        )

      assert %{plan: ["does not lay out as a plan: " <> _how]} = errors_on(check.(plan))
    end

    test "leaves a plan already refused for its heading as it is" do
      changeset =
        {%{}, %{plan: :string}}
        |> cast(%{plan: @old_plan}, [:plan])
        |> add_error(:plan, "must start with `## Implementation plan`")
        |> ImplementationPlan.validate_structure(:plan)

      assert %{plan: ["must start with `## Implementation plan`"]} = errors_on(changeset)
    end
  end

  describe "build_sheet/1" do
    test "splits a plan into its data changes, decisions, cards and numbered criteria" do
      assert %{
               approach: "Sending a task back is a stage move" <> _approach,
               data_changes: [
                 %{
                   kind: "New column",
                   name: "tasks.sent_back_note",
                   description: "text, null until a task is sent back.",
                   markdown: "- New column `tasks.sent_back_note`: text, null until a task is sent back."
                 }
               ],
               decisions: [
                 %{kind: :decision, text: "the note is kept on the task, so the Architect reads it in its brief."},
                 %{kind: :ruled_out, text: "a table of send-backs with their history."},
                 %{kind: :assumption, text: "the note is required.", markdown: "- Assumption: the note is required."}
               ],
               cards: [
                 %{
                   path: "lib/rail/pipeline/actions/send_back_to_architect.ex",
                   deleted?: false,
                   prose: "New action. Refuses unless the task is at `:review` and idle.",
                   signatures: "```elixir\ndef send_back_to_architect(%Run{} = run, note)\n```",
                   sketch: "```elixir sketch\ndef send_back_to_architect" <> _sketch
                 },
                 %{path: "lib/rail_web/live/review_stage.ex", signatures: nil, sketch: nil},
                 %{path: "lib/rail/pipeline.ex", signatures: "```elixir\ndefdelegate" <> _delegate},
                 %{path: "priv/repo/migrations/20261022000000_add_sent_back_note.exs"},
                 %{
                   path: "lib/rail/pipeline/actions/old_send_back.ex",
                   deleted?: true,
                   prose: "The new action replaces it."
                 }
               ],
               criteria: [
                 %{
                   number: 1,
                   files: ["lib/rail/pipeline/actions/send_back_to_architect.ex"],
                   tests: ["lib/rail/pipeline/actions/send_back_to_architect_test.exs"]
                 },
                 %{number: 3, files: ["lib/rail_web/live/review_stage.ex"], tests: []}
               ],
               verification: "- A task sent back from Review is at Architect with the note in its brief."
             } = ImplementationPlan.build_sheet(sheet_plan())
    end

    test "orders the criteria by number, puts a JavaScript test under Test, and keeps a kind written around code" do
      plan =
        sheet_plan()
        |> String.replace("- 3: `lib/rail_web/live/review_stage.ex`", "- 2: `assets/js/a.js` and `assets/test/a.test.js`")
        |> String.replace("- 1: `lib/rail/pipeline/actions/send_back_to_architect.ex`", "- 4: `lib/b.ex`")
        |> String.replace(
          "- New column `tasks.sent_back_note`: text, null until a task is sent back.",
          "- Dropped table `old_notes`"
        )
        |> String.replace("- Decision: the note", "- Decision: `note` and the note")

      assert %{
               criteria: [%{number: 2, files: ["assets/js/a.js"], tests: ["assets/test/a.test.js"]}, %{number: 4}],
               data_changes: [%{kind: "Dropped table", name: "old_notes", description: ""}],
               decisions: [%{kind: :decision, text: "`note` and the note" <> _rest} | _more]
             } = ImplementationPlan.build_sheet(plan)
    end

    test "a plan saved before cards, diagrams and all, builds no sheet" do
      assert ImplementationPlan.build_sheet(@old_plan) == nil
      assert ImplementationPlan.build_sheet("Just prose, no sections at all.") == nil
    end

    test "a plan whose parts do not lay out builds no sheet" do
      for {from, to} <- [
            {"### Approach", "A note first.\n\n### Approach"},
            {"### Verification", "### Rollout\n\nShip it.\n\n### Verification"},
            {"### Verification", "### Approach\n\nAgain.\n\n### Verification"},
            {"### Changes\n", "### Changes\n\nFive files.\n"},
            {"#### `lib/rail_web/live/review_stage.ex`", "#### The review stage"},
            {"#### `lib/rail_web/live/review_stage.ex`", "#### `lib/rail/pipeline.ex`"},
            {"#### `lib/rail_web/live/review_stage.ex`", "#### `lib/rail_web/live/review_stage.ex` renamed"},
            {"Adds the column.\n", "Adds the column.\n\n```sketch\nA\n```\n\n```sketch\nB\n```\n"},
            {"- 3: `lib/rail_web", "- 1: `lib/rail_web"},
            {"- 3: `lib/rail_web/live/review_stage.ex`", "- `lib/rail_web/live/review_stage.ex`"},
            {"- 3: `lib/rail_web/live/review_stage.ex`", "- Three: `lib/rail_web/live/review_stage.ex`"},
            {"- New column `tasks.sent_back_note`:", "- `tasks.sent_back_note`:"},
            {"- New column `tasks.sent_back_note`:", "- New column tasks.sent_back_note:"},
            {"- Assumption: the note", "- We assume the note"},
            {"- Ruled out: a table", "- [ ] Ruled out: a table"},
            {"- Assumption: the note is required.\n", "- Assumption: the note is required.\n\nAnd more.\n"}
          ] do
        assert ImplementationPlan.build_sheet(String.replace(sheet_plan(), from, to)) == nil, "#{from} -> #{to}"
      end
    end
  end

  describe "validate_file_changes/2 and build_file_changes/1" do
    test "read a fix plan's File-level changes as cards, as a plan's Changes" do
      fix_plan = """
      Two changes.

      ### What changes

      #### `nil-crash`

      Guard it.

      ### File-level changes

      #### `lib/a.ex`

      Guards nil. For `nil-crash`.

      ```elixir
      def guard(value)
      ```

      ```elixir sketch
      def guard(nil), do: :error
      ```

      #### `lib/old.ex` deleted

      Nothing calls it. For `nil-crash`.
      """

      changeset =
        {%{}, %{plan: :string}} |> cast(%{plan: fix_plan}, [:plan]) |> ImplementationPlan.validate_file_changes(:plan)

      assert changeset.valid?

      assert [
               %{
                 path: "lib/a.ex",
                 deleted?: false,
                 prose: "Guards nil. For `nil-crash`.",
                 signatures: "```elixir\ndef guard(value)\n```",
                 sketch: "```elixir sketch\ndef guard(nil), do: :error\n```"
               },
               %{path: "lib/old.ex", deleted?: true, signatures: nil, sketch: nil}
             ] = ImplementationPlan.build_file_changes(fix_plan)
    end

    test "read a fix plan saved as bullets before cards as a card of prose per bullet" do
      bullets = "### File-level changes\n\n- `lib/a.ex`: guards nil. For `nil-crash`.\n- `lib/a_test.exs`\n"

      assert [
               %{path: "lib/a.ex", deleted?: false, prose: "guards nil. For `nil-crash`.", sketch: nil},
               %{path: "lib/a_test.exs", prose: ""}
             ] = ImplementationPlan.build_file_changes(bullets)

      assert ImplementationPlan.build_file_changes("### File-level changes\n\n- [ ] `lib/a.ex`: guards it.\n") == nil

      changeset =
        {%{}, %{plan: :string}} |> cast(%{plan: bullets}, [:plan]) |> ImplementationPlan.validate_file_changes(:plan)

      assert %{plan: ["needs `### File-level changes` to be a `#### `path/to/file`` card" <> _rest]} =
               errors_on(changeset)
    end

    test "refuse cards that do not lay out, and take markdown with no such section as it is" do
      two =
        "### File-level changes\n\n#### `lib/a.ex`\n\nGuards it.\n\n```elixir sketch\n:ok\n```\n\n```elixir sketch\n:ok\n```\n"

      changeset =
        {%{}, %{plan: :string}} |> cast(%{plan: two}, [:plan]) |> ImplementationPlan.validate_file_changes(:plan)

      assert %{plan: ["has more than one code block of a kind under `#### `lib/a.ex``" <> _rest]} = errors_on(changeset)

      bare = "### File-level changes\n\n#### lib/a.ex\n\nGuards it.\n"

      changeset =
        {%{}, %{plan: :string}} |> cast(%{plan: bare}, [:plan]) |> ImplementationPlan.validate_file_changes(:plan)

      assert %{plan: ["has a heading under `### File-level changes` that is not" <> _rest]} = errors_on(changeset)

      empty = "### File-level changes\n\n### Verification\n\nRun it."

      changeset =
        {%{}, %{plan: :string}} |> cast(%{plan: empty}, [:plan]) |> ImplementationPlan.validate_file_changes(:plan)

      assert %{plan: ["needs `### File-level changes` to be a `#### `path/to/file`` card" <> _rest]} =
               errors_on(changeset)

      assert ImplementationPlan.build_file_changes(empty) == nil

      none = "### What changes\n\nNothing."

      assert {%{}, %{plan: :string}}
             |> cast(%{plan: none}, [:plan])
             |> ImplementationPlan.validate_file_changes(:plan)
             |> Map.get(:valid?)

      assert ImplementationPlan.build_file_changes(none) == nil
    end
  end
end
