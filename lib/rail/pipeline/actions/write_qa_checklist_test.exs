defmodule Rail.Pipeline.Actions.WriteQaChecklistTest do
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
            "issue" => %{"id" => "lin_wcl_1", "identifier" => "WCL-1", "title" => "Write Checklist"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Write Checklist"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, path: Path.join([task.scratch_path, "qa", "checklist.json"])}
  end

  # The QA directory is made when the run starts, but a checklist written by a
  # pass that got there another way still has to land.
  test "writes the checklist where the panel reads it", %{task: task, path: path} do
    assert {:ok, %{checks: [%{key: "bill-saves", outcome: :pending}, %{key: "totals", criterion: "Totals match"}]}} =
             Pipeline.write_qa_checklist(task, [
               %{"key" => "bill-saves", "title" => "A bill saves and survives a reload"},
               %{"key" => "totals", "title" => "The total agrees with the journal entry", "criterion" => "Totals match"}
             ])

    first = %{
      "key" => "bill-saves",
      "title" => "A bill saves and survives a reload",
      "group" => nil,
      "criterion" => nil,
      "outcome" => "pending",
      "note" => nil,
      "carried" => false
    }

    assert %{"checks" => [^first, %{"criterion" => "Totals match"}]} = path |> File.read!() |> Jason.decode!()
  end

  # A second QA pass lists every check again and re-runs the few the new commits
  # could have touched. What it does not run stands as it was answered, marked as
  # somebody else's work.
  test "a row already answered keeps its outcome and says it was carried", %{task: task} do
    {:ok, _first} =
      Pipeline.write_qa_checklist(task, [
        %{"key" => "bill-saves", "title" => "A bill saves"},
        %{"key" => "totals", "title" => "The totals agree"}
      ])

    {:ok, _marked} = Pipeline.record_qa_check(task, "bill-saves", "pass", "saved to the cent")

    assert {:ok, %{checks: [carried, fresh]}} =
             Pipeline.write_qa_checklist(task, [
               %{"key" => "bill-saves", "title" => "A bill saves"},
               %{"key" => "totals", "title" => "The totals agree"}
             ])

    assert %{key: "bill-saves", outcome: :pass, note: "saved to the cent", carried: true} = carried
    assert %{key: "totals", outcome: :pending, carried: false} = fresh
  end

  # Running it again is what makes it this pass's answer rather than the last
  # one's.
  test "a row this pass runs again is no longer carried", %{task: task} do
    {:ok, _first} = Pipeline.write_qa_checklist(task, [%{"key" => "totals", "title" => "The totals agree"}])
    {:ok, _marked} = Pipeline.record_qa_check(task, "totals", "pass", "they did")

    assert {:ok, %{checks: [%{carried: true}]}} =
             Pipeline.write_qa_checklist(task, [%{"key" => "totals", "title" => "The totals agree"}])

    assert {:ok, %{outcome: :fail, carried: false}} = Pipeline.record_qa_check(task, "totals", "fail", "not now")
  end

  # The list is a statement of the pass rather than a journal of it, so a second
  # call is the whole of it again.
  test "a second call replaces the list rather than adding to it", %{task: task} do
    {:ok, _first} = Pipeline.write_qa_checklist(task, [%{"key" => "one", "title" => "The first idea"}])

    assert {:ok, %{checks: [%{key: "two"}]}} =
             Pipeline.write_qa_checklist(task, [%{"key" => "two", "title" => "The better idea"}])
  end

  test "nothing is written when the list is not usable", %{task: task, path: path} do
    assert {:error, %Ecto.Changeset{}} = Pipeline.write_qa_checklist(task, [%{"title" => "No key on this one"}])
    refute File.exists?(path)
  end
end
