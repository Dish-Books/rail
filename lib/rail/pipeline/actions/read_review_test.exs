defmodule Rail.Pipeline.Actions.ReadReviewTest do
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
            "issue" => %{"id" => "lin_read_review_1", "identifier" => "RDR-1", "title" => "Read Review"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Read Review"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    reviews_dir = Path.join(task.scratch_path, "reviews")
    File.mkdir_p!(reviews_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: Repo.preload(task, :issue), report_path: Path.join(reviews_dir, "RDR-1.json")}
  end

  test "reads the findings the reviewer wrote", %{task: task, report_path: path} do
    File.write!(path, """
    {"findings": [
      {"key": "unhandled-nil", "title": "Nil is not handled", "detail": "The clause assumes a map.",
       "file": "lib/rail/example.ex", "line": 12, "severity": "blocker", "recommendation": "fix", "status": "open"}
    ]}
    """)

    assert [
             %{
               key: "unhandled-nil",
               title: "Nil is not handled",
               detail: "The clause assumes a map.",
               file: "lib/rail/example.ex",
               line: 12,
               severity: :blocker,
               recommendation: :fix,
               status: :open
             }
           ] = Pipeline.read_review(task)
  end

  test "a review that found nothing is an empty list, not nothing", %{task: task, report_path: path} do
    File.write!(path, ~s({"findings": []}))

    assert Pipeline.read_review(task) == []
  end

  test "an unwritten report is no report", %{task: task} do
    assert Pipeline.read_review(task) == nil
  end

  test "a report that is not JSON is no report", %{task: task, report_path: path} do
    File.write!(path, "I looked at it and it seemed fine.")

    assert Pipeline.read_review(task) == nil
  end

  test "a report without a findings list is no report", %{task: task, report_path: path} do
    File.write!(path, ~s({"verdict": "approved"}))

    assert Pipeline.read_review(task) == nil
  end

  test "a finding missing what makes it a finding is dropped", %{task: task, report_path: path} do
    File.write!(path, """
    {"findings": [
      "not even an object",
      {"key": "no-title", "title": "  ", "severity": "major", "recommendation": "fix"},
      {"key": "Not A Slug", "title": "Bad key", "severity": "major", "recommendation": "fix"},
      {"key": "bad-severity", "title": "Unknown severity", "severity": "catastrophic", "recommendation": "fix"},
      {"key": "bad-recommendation", "title": "Unknown advice", "severity": "major", "recommendation": "maybe"},
      {"key": "keeper", "title": "This one is fine", "severity": "minor", "recommendation": "skip"}
    ]}
    """)

    assert [%{key: "keeper", severity: :minor, recommendation: :skip, status: :open}] = Pipeline.read_review(task)
  end

  test "a finding with no location and an unreadable line keeps neither", %{task: task, report_path: path} do
    File.write!(path, """
    {"findings": [
      {"key": "somewhere", "title": "Everywhere and nowhere", "detail": "  ", "line": "not a number",
       "severity": "nit", "recommendation": "skip"}
    ]}
    """)

    assert [%{file: nil, line: nil, detail: nil}] = Pipeline.read_review(task)
  end

  test "a line written as a string is still a line", %{task: task, report_path: path} do
    File.write!(path, """
    {"findings": [
      {"key": "stringly-typed", "title": "Line came back as text", "file": "lib/rail/example.ex", "line": "42",
       "severity": "minor", "recommendation": "fix"}
    ]}
    """)

    assert [%{line: 42}] = Pipeline.read_review(task)
  end

  test "a status the reviewer did not state reads as open", %{task: task, report_path: path} do
    File.write!(path, """
    {"findings": [
      {"key": "no-status", "title": "Said nothing about status", "severity": "major", "recommendation": "fix",
       "status": "invented"}
    ]}
    """)

    assert [%{status: :open}] = Pipeline.read_review(task)
  end
end
