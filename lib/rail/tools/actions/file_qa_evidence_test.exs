defmodule Rail.Tools.Actions.FileQaEvidenceTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_fqe_1", "identifier" => "FQE-1", "title" => "File Evidence"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "File Evidence"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "evidence"))
    outside = Path.join(System.tmp_dir!(), "fqe-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)

    on_exit(fn ->
      File.rm_rf(task.scratch_path)
      File.rm_rf(outside)
    end)

    %{task: task, qa: qa, outside: outside}
  end

  # Rail names the copy the way it names a picture, so the check and the caption
  # come back out of the name and the panel shows it against its row.
  test "a file is copied in under the check it proves", %{task: task, qa: qa} do
    File.write!(Path.join([qa, "evidence", "run.log"]), "wrote 3 rows")

    assert {:ok, "evidence/script-runs~the-script-s-log.log"} =
             Tools.file_qa_evidence(task, "evidence/run.log", "The script's log", "script-runs")

    assert File.read!(Path.join([qa, "evidence", "script-runs~the-script-s-log.log"])) == "wrote 3 rows"
    assert File.read!(Path.join([qa, "evidence", "run.log"])) == "wrote 3 rows"

    # With no worktree and no browser named, there is neither to write down.
    assert [
             %{
               "file" => "script-runs~the-script-s-log.log",
               "name" => "The script's log",
               "commit" => nil,
               "browser" => nil
             }
           ] =
             [qa, "evidence", "captions.jsonl"]
             |> Path.join()
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
  end

  # A finding citing the file copies these, so it can say which commit and which explorer it came from.
  test "a file is written down with the commit and the browser it came from", %{task: task, qa: qa} do
    stub(Rail.Git, :branch_fingerprint, fn _worktree -> %{head_sha: "headsha"} end)
    task = %{task | worktree_path: Path.join(System.tmp_dir!(), "fqe_wt_#{System.unique_integer([:positive])}")}
    File.mkdir_p!(task.worktree_path)
    on_exit(fn -> File.rm_rf(task.worktree_path) end)
    File.write!(Path.join([qa, "evidence", "run.log"]), "wrote 3 rows")

    {:ok, _file} = Tools.file_qa_evidence(task, "evidence/run.log", "The log", "script-runs", "explorer-1")

    assert [%{"file" => "script-runs~the-log.log", "commit" => "headsha", "browser" => "explorer-1"}] =
             [qa, "evidence", "captions.jsonl"]
             |> Path.join()
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)
  end

  test "every page open on the task hears a file filed, and no temporary file is left", %{
    task: %{id: task_id} = task,
    qa: qa
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")
    File.write!(Path.join([qa, "evidence", "run.log"]), "wrote 3 rows")

    assert {:ok, _file} = Tools.file_qa_evidence(task, "evidence/run.log", "The log", "script-runs")

    assert_received {:output_saved, ^task_id}
    assert Path.wildcard(Path.join(qa, ".*"), match_dot: true) == []
  end

  test "the extension is kept, lowercased", %{task: task, qa: qa} do
    File.write!(Path.join(qa, "Invoice.PDF"), "%PDF-1.7")

    assert {:ok, "evidence/invoice~the-invoice.pdf"} =
             Tools.file_qa_evidence(task, "Invoice.PDF", "The invoice", "invoice")
  end

  # Only the QA directory is the agent's to file from; anything else is a way of
  # putting a file from elsewhere on the machine in front of a browser.
  test "a path that is absolute or climbs out is refused and nothing is written", %{task: task, qa: qa} do
    for path <- ["/etc/passwd", "../x.log", "evidence/../../x.log"] do
      assert {:error, :unconfined_path} = Tools.file_qa_evidence(task, path, "Stolen", "totals")
    end

    assert File.ls!(Path.join(qa, "evidence")) == []
  end

  # A name Chrome gives a repeated download is neither absolute nor climbing, and
  # the agent needs to hear that renaming it is all it takes.
  test "a path with characters Rail does not serve is refused as a name", %{task: task, qa: qa} do
    File.write!(Path.join(qa, "statement (1).pdf"), "%PDF-1.7")

    assert {:error, :unusable_name} = Tools.file_qa_evidence(task, "statement (1).pdf", "The statement", "totals")
    assert File.ls!(Path.join(qa, "evidence")) == []
  end

  # Copying a file onto itself empties it, and a filed name is a path the agent
  # has just been handed.
  test "filing a filed file again under its own name keeps it", %{task: task, qa: qa} do
    File.write!(Path.join([qa, "evidence", "totals~the-log.log"]), "wrote 3 rows")

    assert {:ok, "evidence/totals~the-log.log"} =
             Tools.file_qa_evidence(task, "evidence/totals~the-log.log", "The log", "totals")

    assert {:ok, "evidence/totals~the-log.log"} =
             Tools.file_qa_evidence(task, "./evidence/totals~the-log.log", "The log", "totals")

    assert File.read!(Path.join([qa, "evidence", "totals~the-log.log"])) == "wrote 3 rows"
  end

  test "a symlink anywhere on the path is not a file", %{task: task, qa: qa, outside: outside} do
    File.write!(Path.join(outside, "secret.log"), "secret")
    File.ln_s!(Path.join(outside, "secret.log"), Path.join([qa, "evidence", "link.log"]))
    File.ln_s!(outside, Path.join(qa, "linked"))

    assert {:error, :not_a_file} = Tools.file_qa_evidence(task, "evidence/link.log", "The link", "totals")
    assert {:error, :not_a_file} = Tools.file_qa_evidence(task, "linked/secret.log", "The link", "totals")
    refute File.exists?(Path.join([qa, "evidence", "captions.jsonl"]))
  end

  test "a missing file or a directory is not a file", %{task: task} do
    assert {:error, :not_a_file} = Tools.file_qa_evidence(task, "evidence/gone.log", "Gone", "totals")
    assert {:error, :not_a_file} = Tools.file_qa_evidence(task, "evidence", "A directory", "totals")
  end
end
