defmodule Rail.Pipeline.Actions.SavePlanTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  # The smallest plan the structure allows: no diagrams, so Approach says why, and no Program design.
  @plan """
  ## Implementation plan

  ### Approach

  Extend the module.

  No diagrams: one module changes.

  ### File-level changes

  - `lib/rail.ex`: extends the module.

  ### Verification

  - `lib/rail_test.exs`: covers the extension.
  """

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_plan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    task = %Task{
      id: "tsk_save_plan_#{System.unique_integer([:positive])}",
      scratch_path: scratch,
      issue: %Issue{identifier: "SVP-1"}
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    options = [%{"key" => "rows", "title" => "Charts in the row"}, %{"key" => "panel", "title" => "Usage panel"}]
    File.mkdir_p!(Path.join(scratch, "design"))

    write_options = fn ->
      File.write!(Path.join(scratch, "design/manifest.json"), Jason.encode!(%{"options" => options}))
    end

    %{task: task, scratch: scratch, write_options: write_options}
  end

  test "a No diagrams: line run into the Approach paragraph is refused, since the plan would not lay out", %{
    task: task
  } do
    plan = String.replace(@plan, "Extend the module.\n\nNo diagrams:", "Extend the module.\nNo diagrams:")

    assert {:error, changeset} = Pipeline.save_plan(task, %{plan: plan})
    assert %{plan: ["`No diagrams:` must start a paragraph of its own, after a blank line"]} = errors_on(changeset)
    assert Pipeline.read_plan(task) == nil
  end

  test "a plan under the heading is written where read_plan reads it, and broadcast", %{task: %{id: task_id} = task} do
    assert {:ok, %{content: @plan, design: nil}} = Pipeline.save_plan(task, %{plan: @plan})

    assert %{content: @plan, saved_at: %DateTime{}} = Pipeline.read_plan(task)
    assert_received {:output_saved, ^task_id}
  end

  test "a blank plan, or one without the heading, is refused and leaves the earlier plan", %{task: task} do
    {:ok, _first} = Pipeline.save_plan(task, %{plan: @plan})

    assert {:error, blank} = Pipeline.save_plan(task, %{plan: "   "})
    assert %{plan: ["can't be blank"]} = errors_on(blank)

    assert {:error, unheaded} =
             Pipeline.save_plan(task, %{plan: String.replace(@plan, "## Implementation plan", "# Plan")})

    assert %{plan: ["must open with the `## Implementation plan` heading"]} = errors_on(unheaded)

    assert {:error, listed} = Pipeline.save_plan(task, %{plan: ["## Implementation plan"]})
    assert %{plan: ["is invalid"]} = errors_on(listed)

    assert %{content: @plan} = Pipeline.read_plan(task)
  end

  # Rail lays a plan out by its sections, and one shaped otherwise would show as plain text. Each
  # refusal names what to fix, so the agent can save again.
  test "a plan whose sections are off is refused with what to fix, and leaves the earlier plan", %{task: task} do
    {:ok, _first} = Pipeline.save_plan(task, %{plan: @plan})

    refused = fn plan ->
      assert {:error, changeset} = Pipeline.save_plan(task, %{plan: plan})
      errors_on(changeset).plan
    end

    assert ["has text between `## Implementation plan` and `### Approach`; every part of the plan goes under its section"] =
             refused.(String.replace(@plan, "### Approach\n", "Before it all.\n\n### Approach\n"))

    assert ["has a `### Risks` section, but the sections are " <> _titles] =
             refused.(@plan <> "\n### Risks\n\n- None.\n")

    assert ["has `### Verification` more than once"] =
             refused.(@plan <> "\n### Verification\n\n- `lib/more_test.exs`: more.\n")

    assert ["is missing its `### Verification` section"] =
             refused.(String.replace(@plan, ~r/### Verification.*\z/s, ""))

    swapped =
      String.replace(@plan, ~r/(### File-level changes.*?)(### Verification.*)\z/s, "\\2\n\\1")

    assert ["has its sections out of order; they go " <> _titles] = refused.(swapped)

    assert ["leaves out both diagrams, so `### Approach` must end with a line starting `No diagrams:` that says why"] =
             refused.(String.replace(@plan, "No diagrams: one module changes.\n\n", ""))

    one_diagram =
      String.replace(
        @plan,
        "### File-level changes",
        "### Change diagram\n\n```mermaid\nflowchart LR\n```\n\n### File-level changes"
      )

    assert [
             "has one diagram section without the other; include both `### Change diagram` and `### Call flow`, or neither"
           ] =
             refused.(one_diagram)

    no_mermaid =
      String.replace(
        @plan,
        "### File-level changes",
        "### Change diagram\n\nA picture.\n\n### Call flow\n\nIt flows.\n\n### File-level changes"
      )

    assert [
             "needs a ```mermaid block under `### Change diagram`",
             "needs a ```mermaid block under `### Call flow`"
           ] = refused.(no_mermaid)

    assert ["has sub-bullets under `### File-level changes`; it is one flat bullet per file"] =
             refused.(String.replace(@plan, "extends the module.\n", "extends the module.\n  - and more.\n"))

    assert ["has a line under `### File-level changes` that is not a bullet starting with a file path in backticks"] =
             refused.(String.replace(@plan, "- `lib/rail.ex`: extends the module.", "- The module grows."))

    assert ["has nothing under `### File-level changes`; it is one bullet per file, starting with its path in backticks"] =
             refused.(String.replace(@plan, "- `lib/rail.ex`: extends the module.\n", ""))

    assert [
             "needs `### Program design` to start with a `#### `Module.Name`` heading; leave the section out when no signature changes"
           ] =
             refused.(
               String.replace(
                 @plan,
                 "### Verification",
                 "### Program design\n\nNo signature changes.\n\n### Verification"
               )
             )

    assert ["has a heading under `### Program design` that is not `#### `Module.Name``, optionally followed by `new`"] =
             refused.(
               String.replace(@plan, "### Verification", "### Program design\n\n#### the module\n\n### Verification")
             )

    assert ["needs each module under `### Program design` followed by its file path in backticks on a line of its own"] =
             refused.(
               String.replace(
                 @plan,
                 "### Verification",
                 "### Program design\n\n#### `Rail`\n\n```elixir\ndef go\n```\n\n### Verification"
               )
             )

    assert %{content: @plan} = Pipeline.read_plan(task)
  end

  # Code is fenced, so a heading or a bullet inside a block is the code's, not the plan's.
  test "a plan with both diagrams, Program design and Assumptions is saved, whatever its code blocks hold", %{
    task: task
  } do
    plan = """
    ## Implementation plan

    ### Approach

    Extend the module.

    ### Change diagram

    ```mermaid
    flowchart LR
      A["Rail"]
    ```

    ### Call flow

    It starts at the tool and ends in the database.

    ```mermaid
    sequenceDiagram
      Tool->>Rail: save
    ```

    ### File-level changes

    - `lib/rail.ex`: extends the module,
      over two lines.

    ### Program design

    #### `Rail` new

    `lib/rail.ex`

    ```elixir
    ### not a section
    - not a bullet
    def go
    ```

    #### Rail.Other

    `lib/rail/other.ex`

    ```elixir
    def other
    ```

    ### Verification

    - `lib/rail_test.exs`: covers the extension.
      - and its edge.

    ### Assumptions

    - The module stays small.
    """

    assert {:ok, %{content: ^plan}} = Pipeline.save_plan(task, %{plan: plan})
  end

  test "a second save replaces the first", %{task: task} do
    {:ok, _first} = Pipeline.save_plan(task, %{plan: @plan})
    second = String.replace(@plan, "Extend the module.", "Replace the module.")
    {:ok, _second} = Pipeline.save_plan(task, %{plan: second})

    assert %{content: ^second} = Pipeline.read_plan(task)
  end

  test "a plan saved for an option keeps its title after the pick deletes the option", %{
    task: task,
    scratch: scratch,
    write_options: write_options
  } do
    write_options.()

    assert {:ok, %{design: %{key: "panel", title: "Usage panel"}}} =
             Pipeline.save_plan(task, %{"plan" => @plan, "design" => "panel"})

    File.write!(
      Path.join(scratch, "design/manifest.json"),
      ~s({"options": [{"key": "rows", "title": "Charts in the row"}]})
    )

    File.write!(Path.join(scratch, "design/picked"), "rows")

    assert %{design: %{key: "panel", title: "Usage panel"}} = Pipeline.read_plan(task)
  end

  test "a plan saved before the pick with no option names none, and a later save for none clears the option", %{
    task: task,
    write_options: write_options
  } do
    write_options.()

    assert {:ok, %{design: nil}} = Pipeline.save_plan(task, %{plan: @plan})
    assert {:ok, %{design: %{key: "rows"}}} = Pipeline.save_plan(task, %{plan: @plan, design: "rows"})
    assert {:ok, %{design: nil}} = Pipeline.save_plan(task, %{plan: @plan})
    assert %{design: nil} = Pipeline.read_plan(task)
  end

  test "a key naming no option, or any key with no options, is refused and leaves the last good save", %{
    task: task,
    write_options: write_options
  } do
    assert {:error, no_options} = Pipeline.save_plan(task, %{plan: @plan, design: "rows"})
    assert %{design: ["names an option, but no design options are saved; leave it out"]} = errors_on(no_options)

    write_options.()
    good = String.replace(@plan, "Extend the module.", "Good.")
    {:ok, _good} = Pipeline.save_plan(task, %{plan: good, design: "rows"})

    assert {:error, unknown} = Pipeline.save_plan(task, %{plan: @plan, design: "cards"})
    assert %{design: ["cards is not a saved design option; it is one of rows, panel"]} = errors_on(unknown)

    assert %{content: ^good, design: %{key: "rows"}} = Pipeline.read_plan(task)
  end
end
