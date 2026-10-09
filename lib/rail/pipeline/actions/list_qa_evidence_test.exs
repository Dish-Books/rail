defmodule Rail.Pipeline.Actions.ListQaEvidenceTest do
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
            "issue" => %{"id" => "lin_lev_1", "identifier" => "LEV-1", "title" => "List Evidence"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "List Evidence"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    directory = Path.join([task.scratch_path, "qa", "evidence"])
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task, directory: directory}
  end

  # Rail made every one of these names, so the check and the caption come back
  # out of it rather than out of anywhere that had to be kept in step.
  test "reads the check and the caption back out of the name", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "bill-saves~the-saved-bill.jpg"), "jpeg")

    assert [%{name: "The saved bill", file: "bill-saves~the-saved-bill.jpg", check: "bill-saves"}] =
             Pipeline.list_qa_evidence(task)
  end

  # A pass can photograph something before it has a checklist to file it
  # against, and that picture is still a picture.
  test "a shot filed against no check still lists", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "the-login-screen.png"), "png")

    assert [%{name: "The login screen", check: nil}] = Pipeline.list_qa_evidence(task)
  end

  # Newest first, because the one a reader wants while a pass is going is the
  # one it just took. A file no check was filed against is one only a finding
  # cites, so it stays out of the roll.
  test "newest first, and only what was filed against a check", %{task: task, directory: directory} do
    for {file, seconds} <- [
          {"totals~first.jpg", 1_700_000_000},
          {"totals~second.jpg", 1_700_000_060},
          {"totals~the-log.log", 1_700_000_120}
        ] do
      path = Path.join(directory, file)
      File.write!(path, "written")
      File.touch!(path, seconds)
    end

    File.write!(Path.join(directory, "server.log"), "** (RuntimeError) boom")

    assert [
             %{file: "totals~the-log.log", check: "totals", name: "The log", kind: :text},
             %{file: "totals~second.jpg", kind: :screenshot},
             %{file: "totals~first.jpg", kind: :screenshot}
           ] = Pipeline.list_qa_evidence(task)
  end

  # An unfiled file is skipped on its name, so one the agent left unreadable
  # costs the listing nothing.
  test "an unfiled file is never opened", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "server.log"), "** (RuntimeError) boom")
    File.chmod!(Path.join(directory, "server.log"), 0o000)
    File.write!(Path.join(directory, "totals~the-total.png"), "png")

    assert [%{file: "totals~the-total.png"}] = Pipeline.list_qa_evidence(task)
  end

  # What a file is decides how the panel shows it and how it is served, and a
  # name says nothing a model could not have got wrong, so text is read for.
  test "each file says what kind of evidence it is", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "invoice~the-invoice.pdf"), "%PDF-1.7")
    File.write!(Path.join(directory, "export~the-export.bin"), <<0, 159, 146, 150>>)
    File.write!(Path.join(directory, "export~the-rows.csv"), "id,total\n1,2500.00\n")
    File.write!(Path.join(directory, "export~nothing-written.log"), "")

    assert [
             %{file: "export~nothing-written.log", kind: :text},
             %{file: "export~the-export.bin", kind: :file},
             %{file: "export~the-rows.csv", kind: :text},
             %{file: "invoice~the-invoice.pdf", kind: :pdf}
           ] = Enum.sort_by(Pipeline.list_qa_evidence(task), & &1.file)
  end

  test "a filed file takes its caption from beside it too", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "script-runs~the-script-s-log.log"), "wrote 3 rows")

    File.write!(
      Path.join(directory, "captions.jsonl"),
      Jason.encode!(%{file: "script-runs~the-script-s-log.log", name: "The script's log"}) <> "\n"
    )

    assert [%{name: "The script's log", kind: :text, commit: nil, browser: nil}] = Pipeline.list_qa_evidence(task)
  end

  # A pass can drive more than one browser across more than one commit, so a
  # reader needs to know which one a picture came from.
  test "a filed file says the commit and browser it was taken on", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "totals~the-total.png"), "png")

    File.write!(
      Path.join(directory, "captions.jsonl"),
      Jason.encode!(%{file: "totals~the-total.png", name: "The total", commit: "abc1234", browser: "admin"}) <> "\n"
    )

    assert [%{name: "The total", commit: "abc1234", browser: "admin"}] = Pipeline.list_qa_evidence(task)
  end

  # A link is a way of putting a file from anywhere on the machine in the roll,
  # and the roll is what the controller serves.
  test "a symlink is never listed, whatever it is named", %{task: task, directory: directory} do
    outside = Path.join(System.tmp_dir!(), "lev-outside-#{System.unique_integer([:positive])}.log")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)

    File.ln_s!(outside, Path.join(directory, "x~y.log"))
    File.ln_s!(outside, Path.join(directory, "x~y.png"))

    assert [] = Pipeline.list_qa_evidence(task)
  end

  # A filename has lost the capitals and the punctuation by the time it is a
  # filename, so what the caption said is written down beside the picture.
  test "the caption is what the pass wrote, not what the filename kept", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "totals~qa231d-new-1-bill-2-500-00-total.jpg"), "jpeg")

    File.write!(
      Path.join(directory, "captions.jsonl"),
      Jason.encode!(%{file: "totals~qa231d-new-1-bill-2-500-00-total.jpg", name: "QA231D-NEW-1 Bill: $2,500.00 total"}) <>
        "\n"
    )

    assert [%{name: "QA231D-NEW-1 Bill: $2,500.00 total"}] = Pipeline.list_qa_evidence(task)
  end

  # The file is appended to while a pass runs, so its last line can be half
  # written, and a picture from before there were captions has none at all.
  test "an unreadable line is skipped and an uncaptioned picture falls back", %{task: task, directory: directory} do
    File.write!(Path.join(directory, "totals~the-journal-entry.jpg"), "jpeg")

    File.write!(Path.join(directory, "captions.jsonl"), ~s({"file": "totals~the-journ))

    assert [%{name: "The journal entry"}] = Pipeline.list_qa_evidence(task)
  end

  test "a pass that photographed nothing has no directory and no pictures", %{task: task, directory: directory} do
    File.rm_rf!(directory)

    assert [] = Pipeline.list_qa_evidence(task)
  end
end
