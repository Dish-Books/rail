defmodule Rail.Pipeline.Actions.ReadQaEvidenceTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.QaEvidence

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rqe_1", "identifier" => "RQE-1", "title" => "Read Evidence"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Read Evidence"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    directory = Path.join([task.scratch_path, "qa", "evidence"])
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, directory: directory}
  end

  test "reads a filed text file for the panel", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "script-runs~the-log.log"), "wrote 3 rows\n")

    assert [%{kind: :text} = listed] = Pipeline.list_qa_evidence(task)
    assert {:ok, %{text: "wrote 3 rows\n", truncated: false}} = Pipeline.read_qa_evidence(task, listed)
  end

  # A log can run to megabytes, and the panel is a preview with the whole file
  # one click away.
  test "stops at 64 KB and says so", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "script-runs~the-log.log"), String.duplicate("a", 70_000))

    shown = String.duplicate("a", 65_536)

    assert [listed] = Pipeline.list_qa_evidence(task)
    assert {:ok, %{text: ^shown, truncated: true}} = Pipeline.read_qa_evidence(task, listed)
  end

  # The limit is in bytes, so it can land inside a character, and half of one is
  # not text.
  test "drops a character the limit cut in half", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "script-runs~the-log.log"), String.duplicate("a", 65_535) <> "é and more")

    shown = String.duplicate("a", 65_535)

    assert [listed] = Pipeline.list_qa_evidence(task)
    assert {:ok, %{text: ^shown, truncated: true}} = Pipeline.read_qa_evidence(task, listed)
  end

  # Listing reads less of the file than the preview does, so a log can turn to
  # bytes past the point the listing looked at.
  test "a file that stops being text past the listing's look is not text", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "script-runs~the-log.log"), String.duplicate("a", 9_000) <> <<0xFF>>)

    assert [%{kind: :text} = listed] = Pipeline.list_qa_evidence(task)
    assert {:error, :not_text} = Pipeline.read_qa_evidence(task, listed)
  end

  test "a file gone since it was listed is not found", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "script-runs~the-log.log"), "wrote 3 rows")
    assert [listed] = Pipeline.list_qa_evidence(task)
    File.rm!(Path.join(directory, "script-runs~the-log.log"))

    assert {:error, :not_found} = Pipeline.read_qa_evidence(task, listed)
  end

  test "reads a log a finding cites", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "server.log"), "[info] GET /bills\n[error] boom\n")

    assert Pipeline.read_qa_evidence(task, %QaEvidence{kind: :log, path: "evidence/server.log"}) ==
             {:ok, %{text: "[info] GET /bills\n[error] boom\n", truncated: false}}

    File.write!(Path.join(directory, "quiet.log"), "")

    assert Pipeline.read_qa_evidence(task, %QaEvidence{kind: :log, path: "evidence/quiet.log"}) ==
             {:ok, %{text: "", truncated: false}}
  end

  # A finding's log gets the whole column, so it is read further than a preview.
  test "a finding's file is cut at 256 KB, and says so", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "big.log"), String.duplicate("a", 256 * 1024 + 10))

    shown = String.duplicate("a", 256 * 1024)

    assert {:ok, %{text: ^shown, truncated: true}} =
             Pipeline.read_qa_evidence(task, %QaEvidence{kind: :log, path: "evidence/big.log"})

    File.write!(Path.join(directory, "wide.log"), String.duplicate("a", 256 * 1024 - 1) <> "é and more")

    shown = String.duplicate("a", 256 * 1024 - 1)

    assert {:ok, %{text: ^shown, truncated: true}} =
             Pipeline.read_qa_evidence(task, %QaEvidence{kind: :log, path: "evidence/wide.log"})
  end

  test "a finding's file that is missing or not text is not shown", %{task: task, directory: directory} do
    assert Pipeline.read_qa_evidence(task, %QaEvidence{kind: :log, path: "evidence/gone.log"}) ==
             {:error, :not_found}

    File.write!(Path.join(directory, "dump.bin"), <<0xFF, 0xFE, 0x00, 0x81, "x">>)

    assert Pipeline.read_qa_evidence(task, %QaEvidence{kind: :log, path: "evidence/dump.bin"}) ==
             {:error, :not_text}
  end
end
