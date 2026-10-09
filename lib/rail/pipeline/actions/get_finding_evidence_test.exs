defmodule Rail.Pipeline.Actions.GetFindingEvidenceTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_gfe_1", "identifier" => "GFE-1", "title" => "Get Finding Evidence"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Get Finding Evidence"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "shots"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    File.write!(Path.join(qa, "shots/total.png"), "png bytes")
    File.write!(Path.join(qa, "server.log"), "** (RuntimeError) boom")
    File.write!(Path.join(qa, "invoice.pdf"), "%PDF-1.7")
    File.write!(Path.join(qa, "export.bin"), <<0, 159, 146, 150>>)

    {:ok,
     %Finding{
       evidence: [
         %FindingEvidence{path: shot},
         %FindingEvidence{path: log},
         %FindingEvidence{path: pdf},
         %FindingEvidence{path: bin} | _said
       ]
     }} =
      Pipeline.save_finding(task, %{
        key: "total-unrounded",
        kind: :screen,
        raised_by: :explorer,
        title: "The total renders as $1234.5",
        problem: "A bill's total shows one decimal.",
        screen: "Invoices",
        steps: ["Open an invoice"],
        check: "A bill's total reads as money",
        fix: "Round the total to cents.",
        why: "Money reads in cents.",
        rule: "Totals show two decimals.",
        severity: :major,
        recommendation: :fix,
        places: [%{screen: "Invoices"}],
        evidence: [
          %{name: "the total", kind: :screenshot, path: "shots/total.png"},
          %{name: "the stacktrace", kind: :log, path: "server.log"},
          %{name: "the invoice", kind: :log, path: "invoice.pdf"},
          %{name: "the export", kind: :log, path: "export.bin"},
          %{name: "the stored amount", kind: :query, text: "1234.50"},
          %{name: "the clause", kind: :code, file: "lib/a.ex", line: 3}
        ]
      })

    %{task: task, qa: qa, shot: shot, log: log, pdf: pdf, bin: bin}
  end

  # What the file holds picks the kind, because an agent wrote it and chose its name.
  test "each attached file is found by the finding's key and its place, with what it holds", %{
    task: task,
    qa: qa,
    shot: shot,
    log: log,
    pdf: pdf,
    bin: bin
  } do
    shot_file = Path.join(qa, shot)
    log_file = Path.join(qa, log)
    pdf_file = Path.join(qa, pdf)
    bin_file = Path.join(qa, bin)

    assert {:ok, %{file: ^shot_file, kind: :screenshot}} = Pipeline.get_finding_evidence(task, "total-unrounded", 0)
    assert {:ok, %{file: ^log_file, kind: :text}} = Pipeline.get_finding_evidence(task, "total-unrounded", "1")
    assert {:ok, %{file: ^pdf_file, kind: :pdf}} = Pipeline.get_finding_evidence(task, "total-unrounded", 2)
    assert {:ok, %{file: ^bin_file, kind: :file}} = Pipeline.get_finding_evidence(task, "total-unrounded", 3)
  end

  test "a piece with no file of its own, a code range or a value, has nothing to serve", %{task: task} do
    assert {:error, :not_found} = Pipeline.get_finding_evidence(task, "total-unrounded", 4)
    assert {:error, :not_found} = Pipeline.get_finding_evidence(task, "total-unrounded", 5)
  end

  test "an index past the end, negative or not a number, or a key nothing has, is not found", %{task: task} do
    for index <- [6, "9", "-1", "first", "1.5", ""] do
      assert {:error, :not_found} = Pipeline.get_finding_evidence(task, "total-unrounded", index)
    end

    assert {:error, :not_found} = Pipeline.get_finding_evidence(task, "no-such-finding", 0)
  end

  # `lstat` rather than `stat`, so a link swapped in for the copy is never followed out of the folder.
  test "a copy gone or swapped for a symlink since it was attached is not found", %{
    task: task,
    qa: qa,
    shot: shot,
    log: log
  } do
    outside = Path.join(System.tmp_dir!(), "gfe-outside-#{System.unique_integer([:positive])}.log")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)

    File.rm!(Path.join(qa, shot))
    File.rm!(Path.join(qa, log))
    File.ln_s!(outside, Path.join(qa, log))

    assert {:error, :not_found} = Pipeline.get_finding_evidence(task, "total-unrounded", 0)
    assert {:error, :not_found} = Pipeline.get_finding_evidence(task, "total-unrounded", 1)
  end
end
