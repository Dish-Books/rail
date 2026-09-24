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
    {:ok, task} = Pipeline.create_task(issue, :qa)
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
  # one it just took.
  test "newest first, and only what a browser photographed", %{task: task, directory: directory} do
    for {file, seconds} <- [{"totals~first.jpg", 1_700_000_000}, {"totals~second.jpg", 1_700_000_060}] do
      path = Path.join(directory, file)
      File.write!(path, "jpeg")
      File.touch!(path, seconds)
    end

    File.write!(Path.join(directory, "server.log"), "** (RuntimeError) boom")

    assert [%{file: "totals~second.jpg"}, %{file: "totals~first.jpg"}] = Pipeline.list_qa_evidence(task)
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
