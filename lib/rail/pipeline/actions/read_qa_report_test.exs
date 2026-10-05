defmodule Rail.Pipeline.Actions.ReadQaReportTest do
  use ExUnit.Case, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join(System.tmp_dir!(), "read_qa_report_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(scratch, "qa"))
    on_exit(fn -> File.rm_rf(scratch) end)

    %{
      task: %Task{scratch_path: scratch, issue: %Issue{identifier: "RDQ-1"}},
      path: Path.join([scratch, "qa", "RDQ-1.json"])
    }
  end

  test "reads the verdict, the summary and what went unchecked", %{task: task, path: path} do
    File.write!(path, ~s({"verdict": "fail", "summary": " The total is wrong. ", "not_checked": "Plaid."}))

    assert %QaReport{verdict: :fail, summary: "The total is wrong.", not_checked: "Plaid."} =
             Pipeline.read_qa_report(task)
  end

  # Written by the agent before Rail took the file over: the findings in it are
  # ignored, and the verdict still stands.
  test "a report written before this change, findings and all, keeps its verdict", %{task: task, path: path} do
    File.write!(path, """
    {"verdict": "pass", "summary": "Fine.", "findings": [{"key": "k", "title": "t", "evidence": []}]}
    """)

    assert %QaReport{verdict: :pass, summary: "Fine.", not_checked: nil} = Pipeline.read_qa_report(task)
  end

  test "a verdict Rail does not know, or a blank field, reads as none", %{task: task, path: path} do
    File.write!(path, ~s({"verdict": "great", "summary": "  ", "not_checked": 3}))
    assert %QaReport{verdict: nil, summary: nil, not_checked: nil} = Pipeline.read_qa_report(task)

    File.write!(path, ~s({"verdict": 3, "summary": "Fine."}))
    assert %QaReport{verdict: nil, summary: "Fine."} = Pipeline.read_qa_report(task)
  end

  test "a file that is missing or not JSON is no report", %{task: task, path: path} do
    assert Pipeline.read_qa_report(task) == nil

    File.write!(path, "It all looked fine.")
    assert Pipeline.read_qa_report(task) == nil
  end
end
