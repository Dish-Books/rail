defmodule Rail.Mcp.Utils.RunToolQaCheckTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolQaCheck

  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_qck_1", "identifier" => "QCK-1", "title" => "Qa Check"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Qa Check"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  setup %{task: task} do
    {:ok, _checklist} =
      Pipeline.write_qa_checklist(task, [
        %{"key" => "bill-saves", "title" => "A bill saves"},
        %{"key" => "totals", "title" => "The totals agree"}
      ])

    :ok
  end

  test "marks the row and names what it came to", %{task: task} do
    assert {:ok, "totals: Failed."} =
             run_tool_qa_check(task, %{"key" => "totals", "outcome" => "fail", "note" => "off by a cent"}, [])

    assert {:ok, %{checks: [_bill, %{key: "totals", outcome: :fail, note: "off by a cent"}]}} =
             Pipeline.read_qa_checklist(task)
  end

  # Nothing an agent can get wrong is an error: it reads the answer and puts it
  # right on the next call.
  test "every way of getting it wrong answers in words", %{task: task} do
    assert {:ok, unknown} = run_tool_qa_check(task, %{"key" => "invented", "outcome" => "pass"}, [])
    assert unknown =~ ~s(No check called "invented")

    assert {:ok, outcome} = run_tool_qa_check(task, %{"key" => "totals", "outcome" => "probably"}, [])
    assert outcome =~ "`pass`, `fail` or `skipped`"

    assert {:ok, "qa_check needs a `key` and an `outcome`. Nothing was recorded."} =
             run_tool_qa_check(task, %{"key" => "totals"}, [])
  end

  test "there is nothing to mark before a checklist is written", %{task: task} do
    File.rm!(Path.join([task.scratch_path, "qa", "checklist.json"]))

    assert {:ok, none} = run_tool_qa_check(task, %{"key" => "totals", "outcome" => "pass"}, [])
    assert none =~ "no checklist yet"
  end
end
