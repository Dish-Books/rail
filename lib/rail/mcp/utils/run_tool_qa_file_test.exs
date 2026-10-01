defmodule Rail.Mcp.Utils.RunToolQaFileTest do
  use Rail.DataCase, async: true

  import Rail.Mcp.Utils.RunToolQaFile

  alias Rail.Issues
  alias Rail.Pipeline

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_qfl_1", "identifier" => "QFL-1", "title" => "Qa File"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Qa File"})
    {:ok, task} = Pipeline.create_task(issue, :qa)
    File.mkdir_p!(Path.join([task.scratch_path, "qa", "evidence"]))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  setup %{task: task} do
    {:ok, _checklist} =
      Pipeline.write_qa_checklist(task, [
        %{"key" => "script-runs", "title" => "The script writes its log"},
        %{"key" => "totals", "title" => "The totals agree"}
      ])

    :ok
  end

  test "files the file and names what to cite", %{task: task} do
    File.write!(Path.join([task.scratch_path, "qa", "evidence", "run.log"]), "wrote 3 rows")

    assert {:ok, "Filed as evidence/script-runs~the-script-s-log.log. Cite that name in the finding's evidence."} =
             run_tool_qa_file(
               task,
               %{"check" => "script-runs", "name" => "The script's log", "path" => "evidence/run.log"},
               []
             )
  end

  # Nothing an agent can get wrong is an error: it reads the answer and puts it
  # right on the next call.
  test "every way of getting it wrong answers in words", %{task: task} do
    assert {:ok, refused} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "Stolen", "path" => "/etc/passwd"}, [])

    assert refused =~ "never absolute and never climbing out with `..`. Nothing was filed."

    assert {:ok, "No file at evidence/gone.log. Nothing was filed."} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "Gone", "path" => "evidence/gone.log"}, [])

    File.write!(Path.join([task.scratch_path, "qa", "statement (1).pdf"]), "%PDF-1.7")

    assert {:ok, "Rename it to letters, digits, `.`, `_`, `-`, `~` and `/` only, then file it again. Nothing was filed."} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "Statement", "path" => "statement (1).pdf"}, [])

    assert {:ok, "qa_file needs a `check`, a `name` and a `path`. Nothing was filed."} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "No path"}, [])

    assert {:ok, "qa_file needs a `check`, a `name` and a `path`. Nothing was filed."} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "A number", "path" => 12}, [])
  end

  # A mistyped key would file evidence no row shows, while the agent believes the
  # row is evidenced.
  test "a check that is not on the checklist files nothing", %{task: task} do
    File.write!(Path.join([task.scratch_path, "qa", "evidence", "run.log"]), "wrote 3 rows")

    assert {:ok, ~s(No check called "no-such-row" is on the checklist. Nothing was filed.)} =
             run_tool_qa_file(task, %{"check" => "no-such-row", "name" => "The log", "path" => "evidence/run.log"}, [])

    File.rm!(Path.join([task.scratch_path, "qa", "checklist.json"]))

    assert {:ok, "There is no checklist yet. Call qa_plan first. Nothing was filed."} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "The log", "path" => "evidence/run.log"}, [])

    assert ["run.log"] = File.ls!(Path.join([task.scratch_path, "qa", "evidence"]))
  end
end
