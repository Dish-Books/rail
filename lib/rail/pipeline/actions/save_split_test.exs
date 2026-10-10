defmodule Rail.Pipeline.Actions.SaveSplitTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  # The smallest part of a plan the structure allows, trimmed as a save trims it.
  @part String.trim("""
        ## Implementation plan

        ### Approach

        Build it.

        No diagrams: one module changes.

        ### File-level changes

        - `lib/rail.ex`: builds it.

        ### Verification

        - `lib/rail_test.exs`: covers it.
        """)

  setup do
    scratch = Path.join(System.tmp_dir!(), "save_split_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(scratch) end)

    task = %Task{
      id: "tsk_save_split_#{System.unique_integer([:positive])}",
      scratch_path: scratch,
      issue: %Issue{identifier: "SPL-1", title: "Raw ask"}
    }

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    children = [
      %{
        "title" => "Preview deploys",
        "ticket" => "Deploys.",
        "estimate" => 3,
        "plan" => @part
      },
      %{
        "title" => "QA on previews",
        "ticket" => "QA.",
        "estimate" => 2,
        "plan" => @part,
        "builds_on" => [1],
        "builds_screen" => true
      }
    ]

    %{task: task, children: children, path: Path.join([scratch, "splits", "SPL-1.json"])}
  end

  test "a complete split reads back in order, and every open page hears", %{
    task: %{id: task_id} = task,
    children: children
  } do
    assert {:ok,
            %{
              children: [
                %{
                  number: 1,
                  title: "Preview deploys",
                  ticket: "Deploys.",
                  estimate: 3,
                  builds_on: [],
                  builds_screen: false
                },
                %{number: 2, title: "QA on previews", plan: @part, builds_on: [1], builds_screen: true}
              ],
              saved_at: %DateTime{}
            }} = Pipeline.save_split(task, %{"children" => children})

    assert %{children: [%{number: 1, builds_screen: false}, %{number: 2, builds_screen: true}]} =
             Pipeline.read_split(task)

    assert_received {:output_saved, ^task_id}
  end

  # An agent leaves out a field it means as false, or sends it as null.
  test "a child sent with builds_screen null or left out builds no screen", %{task: task, children: [first, second]} do
    assert {:ok, %{children: [%{builds_screen: false}, %{builds_screen: false}]}} =
             Pipeline.save_split(task, %{"children" => [first, Map.put(second, "builds_screen", nil)]})

    assert %{children: [%{builds_screen: false}, %{builds_screen: false}]} = Pipeline.read_split(task)
  end

  test "a child missing its title, ticket or part of the plan is refused naming it, and the last save stays", %{
    task: %{id: task_id} = task,
    children: [first, second] = children
  } do
    {:ok, _saved} = Pipeline.save_split(task, %{"children" => children})
    assert_received {:output_saved, ^task_id}

    for field <- [:title, :ticket, :plan] do
      left_out = Map.delete(second, Atom.to_string(field))
      assert {:error, changeset} = Pipeline.save_split(task, %{"children" => [first, left_out]})
      assert %{children: [%{}, %{^field => ["can't be blank"]}]} = errors_on(changeset)
    end

    assert %{children: [%{title: "Preview deploys"}, %{title: "QA on previews"}]} = Pipeline.read_split(task)
    refute_received {:output_saved, ^task_id}
  end

  test "a split of one, a two-line title, a negative estimate, a plan without its heading and a later dependency are refused",
       %{task: task, children: [first, second]} do
    assert {:error, changeset} = Pipeline.save_split(task, %{"children" => [first]})
    assert %{children: ["a split needs at least two children"]} = errors_on(changeset)

    assert {:error, changeset} = Pipeline.save_split(task, %{})
    assert %{children: ["a split needs at least two children"]} = errors_on(changeset)

    bad = [
      {%{"title" => "Two\nlines"}, :title, "must be one line"},
      {%{"estimate" => -1}, :estimate, "must be zero or more"},
      {%{"plan" => "Just do it."}, :plan, "must open with the `## Implementation plan` heading"},
      {%{"builds_on" => [2]}, :builds_on, "must name only earlier children, numbered from 1"}
    ]

    for {change, field, message} <- bad do
      assert {:error, changeset} = Pipeline.save_split(task, %{"children" => [first, Map.merge(second, change)]})
      assert %{children: [%{}, %{^field => [^message]}]} = errors_on(changeset)
    end

    assert Pipeline.read_split(task) == nil
  end

  test "a child's part of the plan whose sections are off is refused naming it, and the last save stays", %{
    task: %{id: task_id} = task,
    children: [first, second] = children
  } do
    {:ok, _saved} = Pipeline.save_split(task, %{"children" => children})
    assert_received {:output_saved, ^task_id}

    off = String.replace(@part, "### Approach", "A sentence first.\n\n### Approach")
    assert {:error, changeset} = Pipeline.save_split(task, %{"children" => [first, %{second | "plan" => off}]})

    assert %{children: [%{}, %{plan: ["has text between `## Implementation plan` and `### Approach`" <> _rest]}]} =
             errors_on(changeset)

    assert %{children: [%{plan: @part}, %{plan: @part}]} = Pipeline.read_split(task)
    refute_received {:output_saved, ^task_id}
  end

  test "a child's part whose No diagrams: line runs into the paragraph above is refused naming it", %{
    task: task,
    children: [first, second] = children
  } do
    {:ok, _saved} = Pipeline.save_split(task, %{"children" => children})
    run_on = String.replace(@part, "Build it.\n\nNo diagrams:", "Build it.\nNo diagrams:")

    assert {:error, changeset} = Pipeline.save_split(task, %{"children" => [first, %{second | "plan" => run_on}]})

    assert %{children: [%{}, %{plan: ["`No diagrams:` must start a paragraph of its own, after a blank line"]}]} =
             errors_on(changeset)

    assert %{children: [%{plan: @part}, %{plan: @part}]} = Pipeline.read_split(task)
  end

  test "a child whose builds_on is null builds on nothing, so the split reads back whole", %{
    task: task,
    children: [first, second]
  } do
    assert {:ok, %{children: [%{builds_on: []}, %{builds_on: []}]}} =
             Pipeline.save_split(task, %{
               "children" => [Map.put(first, "builds_on", nil), Map.put(second, "builds_on", nil)]
             })

    assert %{children: [%{builds_on: []}, %{builds_on: []}]} = Pipeline.read_split(task)
  end

  test "an empty list removes the split", %{task: %{id: task_id} = task, children: children, path: path} do
    {:ok, _saved} = Pipeline.save_split(task, %{"children" => children})
    assert File.exists?(path)

    assert {:ok, nil} = Pipeline.save_split(task, %{children: []})
    assert Pipeline.read_split(task) == nil
    assert_received {:output_saved, ^task_id}
  end
end
