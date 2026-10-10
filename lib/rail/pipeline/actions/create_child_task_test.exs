defmodule Rail.Pipeline.Actions.CreateChildTaskTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    for {id, identifier} <- [{"lin_cct_parent", "CCT-1"}, {"lin_cct_child", "CCT-2"}] do
      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => id, "identifier" => identifier, "title" => identifier}
            }
          }
        })
      end)
    end

    {:ok, parent_issue} = Issues.create_issue(system_scope(), project, %{title: "The parent"})
    {:ok, parent} = Pipeline.create_task(parent_issue, :split)
    on_exit(fn -> File.rm_rf(parent.scratch_path) end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "The child", parent: parent_issue})

    %{parent: parent, issue: issue}
  end

  test "a child that builds the screen is at Engineer under its parent, with its part as the plan and the picked design",
       %{
         parent: %Task{id: parent_id} = parent,
         issue: %{id: issue_id} = issue
       } do
    design = Path.join(parent.scratch_path, "design")
    File.mkdir_p!(design)
    File.write!(Path.join(design, "manifest.json"), ~s({"options": [{"key": "board", "title": "Board"}]}))
    File.write!(Path.join(design, "board.html"), "<h1>Board</h1>")
    File.write!(Path.join(design, "picked"), "board")

    child = %{number: 2, builds_on: [1], builds_screen: true, plan: "## Implementation plan\n\nMy part."}

    assert {:ok,
            %Task{stage: :engineer, parent_task_id: ^parent_id, issue_id: ^issue_id, split_position: 2, builds_on: [1]} =
              task} =
             Pipeline.create_child_task(parent, issue, child)

    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    assert {:ok, %ImplementationPlan{content: "## Implementation plan\n\nMy part."}} =
             Pipeline.get_implementation_plan(task)

    assert %{picked: "board", options: [%{key: "board", html: "<h1>Board</h1>"}]} = Pipeline.read_design(task)
  end

  test "a child that builds no screen gets no copy of its parent's design", %{parent: parent, issue: issue} do
    design = Path.join(parent.scratch_path, "design")
    File.mkdir_p!(design)
    File.write!(Path.join(design, "manifest.json"), ~s({"options": [{"key": "board", "title": "Board"}]}))
    File.write!(Path.join(design, "board.html"), "<h1>Board</h1>")
    File.write!(Path.join(design, "picked"), "board")

    assert {:ok, task} =
             Pipeline.create_child_task(parent, issue, %{
               number: 1,
               builds_on: [],
               builds_screen: false,
               plan: "## Implementation plan"
             })

    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    refute File.exists?(Path.join(task.scratch_path, "design"))
    assert Pipeline.read_design(task) == nil
  end

  test "a parent with no design leaves the child with none", %{parent: parent, issue: issue} do
    assert {:ok, task} =
             Pipeline.create_child_task(parent, issue, %{
               number: 1,
               builds_on: [],
               builds_screen: false,
               plan: "## Implementation plan"
             })

    assert Pipeline.read_design(task) == nil
  end

  test "a second child at the same place of one parent is refused", %{parent: parent, issue: issue, project: project} do
    {:ok, _first} =
      Pipeline.create_child_task(parent, issue, %{
        number: 1,
        builds_on: [],
        builds_screen: false,
        plan: "## Implementation plan"
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_cct_again", "identifier" => "CCT-3", "title" => "Again"}
          }
        }
      })
    end)

    {:ok, again} = Issues.create_issue(system_scope(), project, %{title: "Again"})

    assert {:error, changeset} =
             Pipeline.create_child_task(parent, again, %{
               number: 1,
               builds_on: [],
               builds_screen: false,
               plan: "## Implementation plan"
             })

    assert %{split_position: ["has already been taken"]} = errors_on(changeset)
  end
end
