defmodule Rail.Pipeline.Actions.ReadDemoTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Demo

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rdm_1", "identifier" => "RDM-1", "title" => "Read Demo"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Read Demo"})
    {:ok, task} = Pipeline.create_task(issue, :demo)

    demo_dir = Path.join(task.scratch_path, "demo")
    File.mkdir_p!(demo_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: Repo.preload(task, :issue), write_up: Path.join(demo_dir, "RDM-1.json")}
  end

  test "reads what the run said it filmed", %{task: task, write_up: write_up} do
    File.write!(write_up, """
    {
      "title": "Bills can be entered from a photo",
      "summary": "A photographed bill is read, checked and saved.",
      "not_shown": "The Stripe callback, which needs a real card."
    }
    """)

    assert %Demo{
             title: "Bills can be entered from a photo",
             summary: "A photographed bill is read, checked and saved.",
             not_shown: "The Stripe callback, which needs a real card."
           } = Pipeline.read_demo(task)
  end

  test "a walkthrough that covered everything says nothing about what it did not", %{task: task, write_up: write_up} do
    File.write!(write_up, ~s({"title": "Bills", "summary": "It works.", "not_shown": "   "}))

    assert %Demo{not_shown: nil} = Pipeline.read_demo(task)
  end

  test "a task whose run has not written yet has no demo", %{task: task} do
    assert Pipeline.read_demo(task) == nil
  end

  # The file is the agent's word rather than Rail's, so anything that is not the
  # shape agreed reads as no demo instead of a crash.
  test "a file that is not the shape agreed is no demo at all", %{task: task, write_up: write_up} do
    File.write!(write_up, "half a fi")
    assert Pipeline.read_demo(task) == nil

    File.write!(write_up, ~s({"title": "Bills"}))
    assert Pipeline.read_demo(task) == nil
  end
end
