defmodule Rail.Pipeline.Actions.ReadQaReportTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaReport

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_read_qa_1", "identifier" => "RDQ-1", "title" => "Read Qa"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Read Qa"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    qa_dir = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(qa_dir)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: Repo.preload(task, :issue), report_path: Path.join(qa_dir, "RDQ-1.json")}
  end

  test "reads the verdict, what it could not check, and the findings", %{task: task, report_path: path} do
    File.mkdir_p!(Path.join(Path.dirname(path), "evidence"))
    File.write!(Path.join([Path.dirname(path), "evidence", "total.png"]), "png bytes")

    File.write!(path, """
    {
      "verdict": "fail",
      "summary": "The form saves but the total is wrong.",
      "not_checked": "The Plaid callback, which needs a real bank.",
      "findings": [
        {"key": "total-unrounded", "title": "The total renders as $1234.5",
         "check": "A bill's total reads as money", "criterion": "Totals read as money",
         "screen": "/bills/new", "steps": "1. Open a new bill\\n2. Enter 1234.50",
         "expected": "$1,234.50", "observed": "$1234.5",
         "detail": "Every bill screen reads this way.", "suggestion": "Format with Money.to_string/1.",
         "severity": "major", "recommendation": "fix", "caused_by_change": true, "status": "open",
         "evidence": [{"name": "the total", "kind": "screenshot", "path": "evidence/total.png"}]}
      ]
    }
    """)

    summary = "The form saves but the total is wrong."
    not_checked = "The Plaid callback, which needs a real bank."

    assert %QaReport{verdict: :fail, summary: ^summary, not_checked: ^not_checked, findings: [finding]} =
             Pipeline.read_qa_report(task)

    assert %{
             key: "total-unrounded",
             title: "The total renders as $1234.5",
             check: "A bill's total reads as money",
             criterion: "Totals read as money",
             screen: "/bills/new",
             expected: "$1,234.50",
             observed: "$1234.5",
             severity: :major,
             recommendation: :fix,
             caused_by_change: true,
             status: :open,
             evidence: [%{name: "the total", kind: :screenshot, path: "evidence/total.png"}],
             steps: "1. Open a new bill\n2. Enter 1234.50"
           } = finding
  end

  test "a pass that found nothing is not the same as no pass at all", %{task: task, report_path: path} do
    File.write!(path, ~s({"verdict": "pass", "findings": []}))

    assert %QaReport{verdict: :pass, findings: [], summary: nil, not_checked: nil} =
             Pipeline.read_qa_report(task)
  end

  test "a report that is not there, not JSON, or not the shape agreed reads as nothing", %{
    task: task,
    report_path: path
  } do
    assert Pipeline.read_qa_report(task) == nil

    File.write!(path, "")
    assert Pipeline.read_qa_report(task) == nil

    File.write!(path, "It all looked fine to me.")
    assert Pipeline.read_qa_report(task) == nil

    File.write!(path, ~s({"verdict": "pass"}))
    assert Pipeline.read_qa_report(task) == nil

    File.write!(path, ~s({"findings": {"key": "not-a-list"}}))
    assert Pipeline.read_qa_report(task) == nil
  end

  test "a finding Rail cannot read is dropped and the rest survive", %{task: task, report_path: path} do
    good = ~s({"key": "good", "title": "Good", "check": "A check", "severity": "minor", "recommendation": "skip"})

    malformed = [
      ~s({"title": "No key", "check": "A check", "severity": "minor", "recommendation": "skip"}),
      ~s({"key": "Not A Slug", "title": "Bad key", "check": "A check", "severity": "minor", "recommendation": "skip"}),
      ~s({"key": "no-title", "title": "  ", "check": "A check", "severity": "minor", "recommendation": "skip"}),
      ~s({"key": "no-check", "title": "No check", "check": " ", "severity": "minor", "recommendation": "skip"}),
      ~s({"key": "bad-severity", "title": "T", "check": "A check", "severity": "cosmetic", "recommendation": "skip"}),
      ~s({"key": "no-recommendation", "title": "T", "check": "A check", "severity": "minor"}),
      ~s("a finding that is a string")
    ]

    File.write!(path, ~s({"findings": [#{Enum.join(malformed, ", ")}, #{good}]}))

    assert %QaReport{findings: [%{key: "good"}]} = Pipeline.read_qa_report(task)
  end

  test "a verdict Rail does not know loses the verdict, not the findings", %{task: task, report_path: path} do
    File.write!(path, """
    {"verdict": "mostly ok", "findings": [
      {"key": "one", "title": "One", "check": "A check", "severity": "nit", "recommendation": "skip"}
    ]}
    """)

    assert %QaReport{verdict: nil, findings: [%{key: "one"}]} = Pipeline.read_qa_report(task)
  end

  test "evidence that would reach outside the QA directory is dropped, the finding is not", %{
    task: task,
    report_path: path
  } do
    File.mkdir_p!(Path.join(Path.dirname(path), "evidence"))
    File.write!(Path.join([Path.dirname(path), "evidence", "fine.png"]), "png bytes")

    File.write!(path, """
    {"findings": [
      {"key": "one", "title": "One", "check": "A check", "severity": "nit", "recommendation": "skip",
       "evidence": [
         "a bare string where a piece of evidence should be",
         {"kind": "screenshot", "path": "evidence/fine.png"},
         {"name": 12, "kind": "screenshot", "path": "evidence/fine.png"},
         {"name": "climbing", "kind": "screenshot", "path": "../../etc/passwd"},
         {"name": "absolute", "kind": "screenshot", "path": "/etc/passwd"},
         {"name": "nameless", "kind": "screenshot", "path": "evidence/fine.png", "x": 1},
         {"name": "unknown kind", "kind": "hologram", "path": "evidence/fine.png"},
         {"name": "shows nothing", "kind": "note"},
         {"name": "fine", "kind": "screenshot", "path": "evidence/fine.png"}
       ]},
      {"key": "two", "title": "Two", "check": "A check", "severity": "nit", "recommendation": "skip",
       "evidence": [{"name": "the export", "kind": "log", "path": "../../tmp/x.csv"}]}
    ]}
    """)

    assert %QaReport{
             findings: [
               %{
                 evidence: [%{name: "nameless"}, %{name: "fine", path: "evidence/fine.png"}],
                 refused: [
                   "an entry with no name or kind",
                   "an entry with no name or kind",
                   "an entry with no name or kind",
                   "../../etc/passwd is outside the QA folder",
                   "/etc/passwd is outside the QA folder",
                   "an entry with no name or kind",
                   "shows nothing has no file and no text"
                 ]
               },
               %{evidence: [], refused: ["../../tmp/x.csv is outside the QA folder"]}
             ]
           } = Pipeline.read_qa_report(task)
  end

  test "a path inside the QA folder that names no file is refused", %{task: task, report_path: path} do
    File.write!(path, """
    {"findings": [
      {"key": "one", "title": "One", "check": "A check", "severity": "nit", "recommendation": "skip",
       "evidence": [{"name": "the log", "kind": "log", "path": "evidence/server.log"}]}
    ]}
    """)

    assert %QaReport{findings: [%{evidence: [], refused: ["evidence/server.log is not a file in the QA folder"]}]} =
             Pipeline.read_qa_report(task)
  end

  test "text written inline is evidence on its own, even beside a path Rail refused", %{
    task: task,
    report_path: path
  } do
    File.write!(path, """
    {"findings": [
      {"key": "one", "title": "One", "check": "A check", "severity": "nit", "recommendation": "skip",
       "evidence": [
         {"name": "what the database holds", "kind": "query", "text": "amount_cents: 123450"},
         {"name": "the log", "kind": "log", "path": "../server.log", "text": "[error] boom"}
       ]}
    ]}
    """)

    assert %QaReport{
             findings: [
               %{
                 evidence: [
                   %{name: "what the database holds", path: nil, text: "amount_cents: 123450"},
                   %{name: "the log", path: nil, text: "[error] boom"}
                 ],
                 refused: ["../server.log is outside the QA folder"]
               }
             ]
           } = Pipeline.read_qa_report(task)
  end

  # `qa_shot` and `qa_file` name what they file `<check>~<caption>`, and tell the
  # agent to cite exactly that.
  test "evidence citing a name Rail filed is kept", %{task: task, report_path: path} do
    File.mkdir_p!(Path.join(Path.dirname(path), "evidence"))
    File.write!(Path.join([Path.dirname(path), "evidence", "statement~the-statement.pdf"]), "%PDF-1.7")
    File.write!(Path.join([Path.dirname(path), "evidence", "statement~the-download.jpg"]), "jpeg bytes")

    File.write!(path, """
    {"findings": [
      {"key": "one", "title": "One", "check": "statement", "severity": "nit", "recommendation": "skip",
       "evidence": [
         {"name": "the statement", "kind": "log", "path": "evidence/statement~the-statement.pdf"},
         {"name": "the screen", "kind": "screenshot", "path": "evidence/statement~the-download.jpg"}
       ]}
    ]}
    """)

    assert %QaReport{
             findings: [
               %{
                 evidence: [
                   %{path: "evidence/statement~the-statement.pdf"},
                   %{path: "evidence/statement~the-download.jpg"}
                 ]
               }
             ]
           } = Pipeline.read_qa_report(task)
  end

  test "what QA left blank comes back as nothing, and what it left out has a default", %{
    task: task,
    report_path: path
  } do
    File.write!(path, """
    {"findings": [
      {"key": "sparse", "title": "  Sparse  ", "check": " A check ", "criterion": "   ", "screen": "",
       "steps": "", "expected": " ", "observed": "", "detail": "", "suggestion": "",
       "severity": "nit", "recommendation": "skip"}
    ]}
    """)

    assert %QaReport{findings: [finding]} = Pipeline.read_qa_report(task)

    assert %{
             title: "Sparse",
             check: "A check",
             criterion: nil,
             screen: nil,
             steps: nil,
             expected: nil,
             observed: nil,
             detail: nil,
             suggestion: nil,
             status: :open,
             caused_by_change: true,
             evidence: [],
             refused: []
           } = finding
  end
end
