defmodule Rail.Mcp.Utils.RunToolSaveFindingTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolSaveFinding

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaFinding
  alias Rail.Pipeline.Schemas.ReviewFinding

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

    %{task: task, finding: %{"key" => "k", "title" => "T", "severity" => "minor", "recommendation" => "fix"}}
  end

  test "a review run's finding goes to review, taking only review's fields", %{task: task, finding: finding} do
    assert {:ok, "Saved finding k (minor)."} =
             run_tool_save_finding(task, Map.merge(finding, %{"file" => "lib/a.ex", "decision" => "skip"}),
               stage: :review
             )

    assert [%ReviewFinding{key: "k", file: "lib/a.ex", decision: nil}] = Pipeline.list_review_findings(task)
    assert Pipeline.list_qa_findings(task) == []
  end

  test "a QA run's finding goes to QA, with its evidence counted", %{task: task, finding: finding} do
    one = [%{"name" => "seen", "kind" => "note", "text" => "1234.5"}]

    two = [
      %{"name" => "seen", "kind" => "note", "text" => "1234.5"},
      %{"name" => "again", "kind" => "note", "text" => "1234.5"}
    ]

    qa = Map.merge(finding, %{"check" => "totals", "file" => "lib/a.ex"})

    assert {:ok, "Saved finding k (minor) with 1 piece of evidence."} =
             run_tool_save_finding(task, Map.put(qa, "evidence", one), stage: :qa)

    assert {:ok, "Saved finding k (minor) with 2 pieces of evidence."} =
             run_tool_save_finding(task, Map.put(qa, "evidence", two), stage: :qa)

    assert [%QaFinding{key: "k", check: "totals"}] = Pipeline.list_qa_findings(task)
    assert Pipeline.list_review_findings(task) == []
  end

  test "a refusal is passed back as the changeset", %{task: task} do
    assert {:error, %Ecto.Changeset{valid?: false}} = run_tool_save_finding(task, %{"key" => "k"}, stage: :review)
  end
end
