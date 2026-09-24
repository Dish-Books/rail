defmodule Rail.Pipeline.Actions.RecordQaCheckTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rck_1", "identifier" => "RCK-1", "title" => "Record Check"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Record Check"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, _checklist} =
      Pipeline.write_qa_checklist(task, [
        %{"key" => "bill-saves", "title" => "A bill saves", "criterion" => "A bill saves"},
        %{"key" => "totals", "title" => "The totals agree"}
      ])

    %{task: task}
  end

  test "marks one row and leaves the others where they were", %{task: task} do
    assert {:ok, %{key: "bill-saves", outcome: :pass, note: "saved and came back on reload", criterion: "A bill saves"}} =
             Pipeline.record_qa_check(task, "bill-saves", "pass", "saved and came back on reload")

    assert {:ok, %{checks: [%{outcome: :pass}, %{key: "totals", outcome: :pending}]}} =
             Pipeline.read_qa_checklist(task)
  end

  # A pass that comes back to a row it already ran says so rather than being told
  # it has had its turn.
  test "a row can be marked again", %{task: task} do
    {:ok, _first} = Pipeline.record_qa_check(task, "totals", "fail", "off by a cent")

    assert {:ok, %{outcome: :pass}} = Pipeline.record_qa_check(task, "totals", "pass", "fixed by a reload")
  end

  test "a note is optional, and marking again without one keeps the last", %{task: task} do
    {:ok, _noted} = Pipeline.record_qa_check(task, "totals", "fail", "off by a cent")

    assert {:ok, %{outcome: :pass, note: "off by a cent"}} = Pipeline.record_qa_check(task, "totals", "pass")
  end

  test "a row the checklist does not name is refused", %{task: task} do
    assert {:error, :qa_check_not_found} = Pipeline.record_qa_check(task, "invented", "pass")
  end

  test "an outcome Rail does not know records nothing", %{task: task} do
    assert {:error, :unusable_outcome} = Pipeline.record_qa_check(task, "totals", "probably")
    assert {:ok, %{checks: [_bill, %{key: "totals", outcome: :pending}]}} = Pipeline.read_qa_checklist(task)
  end

  test "there is nothing to mark before a checklist is written", %{task: task} do
    File.rm!(Path.join([task.scratch_path, "qa", "checklist.json"]))

    assert {:error, :qa_checklist_not_found} = Pipeline.record_qa_check(task, "totals", "pass")
  end
end
