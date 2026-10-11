defmodule Rail.Mcp.Utils.RunToolSaveFindingTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveFinding

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingNote

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rtsf_1", "identifier" => "RTSF-1", "title" => "Run Tool Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Run Tool Finding"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    finding = %{
      "key" => "unhandled-nil",
      "kind" => "code",
      "raised_by" => "code_reviewer",
      "title" => "Nil is not handled",
      "problem" => "A task with no worktree crashes the page.",
      "file" => "lib/a.ex",
      "line" => 3,
      "fix" => "Guard the nil in the action.",
      "why" => "It crashes.",
      "rule" => "Every caller handles a missing worktree.",
      "severity" => "major",
      "recommendation" => "fix",
      "places" => [%{"file" => "lib/a.ex", "line" => 3, "label" => "handle/1"}],
      "evidence" => [%{"name" => "The clause", "kind" => "code", "file" => "lib/a.ex", "line" => 3}]
    }

    %{task: task, finding: finding}
  end

  test "a new finding is saved whole, in its round, with its evidence counted", %{task: task, finding: finding} do
    assert {:ok, "Saved finding unhandled-nil (major) in round 1 with 1 piece of evidence."} =
             run_tool_save_finding(task, Map.put(finding, "decision", "skip"), [])

    # A ruling is the human's, so one arriving from the agent is dropped.
    assert [%Finding{key: "unhandled-nil", file: "lib/a.ex", decision: nil}] = Pipeline.list_findings(task)
  end

  test "past Review a new finding is refused with where the task is, for the agent to say in the conversation",
       %{task: task, finding: finding} do
    {:ok, finalizing} = Pipeline.update_task(task, %{stage: :finalize})

    assert {:refused, "Nothing saved: the review is finished and the task is at Finalize" <> rest} =
             run_tool_save_finding(finalizing, finding, [])

    assert rest =~ "in the conversation"

    {:ok, merged} = Pipeline.update_task(finalizing, %{stage: :merged})

    assert {:refused, "Nothing saved: the review is finished and the task has merged" <> _rest} =
             run_tool_save_finding(merged, finding, [])

    assert [] = Pipeline.list_findings(task)
  end

  test "more than one piece of evidence is counted in pieces", %{task: task, finding: finding} do
    evidence = [
      %{"name" => "The clause", "kind" => "code", "file" => "lib/a.ex", "line" => 3},
      %{"name" => "The crash", "kind" => "note", "text" => "** (FunctionClauseError)"}
    ]

    assert {:ok, "Saved finding unhandled-nil (major) in round 1 with 2 pieces of evidence."} =
             run_tool_save_finding(task, Map.put(finding, "evidence", evidence), [])
  end

  test "a later save of a known key notes its status and leaves what it said", %{task: task, finding: finding} do
    {:ok, _saved} = run_tool_save_finding(task, finding, [])

    assert {:ok, "Noted unhandled-nil as fixed. What it said when raised stands."} =
             run_tool_save_finding(
               task,
               %{"key" => "unhandled-nil", "status" => "fixed", "title" => "Rewritten", "note" => "Guarded now."},
               []
             )

    assert [%Finding{title: "Nil is not handled", status: :fixed}] = Pipeline.list_findings(task)
  end

  test "a Fix finding a pass finds still failing is said to be carried into the round", %{
    task: task,
    finding: finding
  } do
    {:ok, _saved} = run_tool_save_finding(task, finding, [])
    [raised] = Pipeline.list_findings(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), raised, :fix)

    assert {:ok, "Noted unhandled-nil as not_fixed and carried it into round 1. What it said when raised stands."} =
             run_tool_save_finding(task, %{"key" => "unhandled-nil", "status" => "not_fixed", "note" => "Still nil."}, [])
  end

  test "a fix report on a Fix finding is saved fixed with its covered and left places, test and files", %{
    task: task,
    finding: finding
  } do
    places = [%{"file" => "lib/a.ex", "line" => 3}, %{"file" => "lib/b.ex", "line" => 9}]
    {:ok, _saved} = run_tool_save_finding(task, %{finding | "places" => places}, [])
    [raised] = Pipeline.list_findings(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), raised, :fix)

    report = %{
      "key" => "unhandled-nil",
      "status" => "fixed",
      "covered" => [1],
      "left" => [%{"place" => 2, "reason" => "Generated from a.ex."}],
      "test" => %{"file" => "test/a_test.exs", "name" => "handles nil"},
      "files" => ["lib/a.ex"],
      "note" => "Guarded now."
    }

    assert {:ok, "Noted unhandled-nil as fixed. What it said when raised stands."} =
             run_tool_save_finding(task, report, [])

    assert [
             %Finding{
               status: :fixed,
               notes: [
                 %FindingNote{kind: :raised},
                 %FindingNote{kind: :ruling},
                 %FindingNote{
                   kind: :fix,
                   covered: ["lib/a.ex:3"],
                   left: ["lib/b.ex:9: Generated from a.ex."],
                   test: "test/a_test.exs: handles nil",
                   files: ["lib/a.ex"]
                 }
               ]
             }
           ] = Pipeline.list_findings(task)
  end

  test "a refusal is passed back as the changeset that names the field", %{task: task, finding: finding} do
    assert {:error, %Ecto.Changeset{} = changeset} =
             run_tool_save_finding(task, Map.delete(finding, "evidence"), [])

    assert %{evidence: ["needs at least one highlighted code range, screenshot, file or note"]} = errors_on(changeset)
  end
end
