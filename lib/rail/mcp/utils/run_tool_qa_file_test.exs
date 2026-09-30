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

    assert {:ok, "qa_file needs a `check`, a `name` and a `path`."} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "No path"}, [])

    assert {:ok, "qa_file needs a `check`, a `name` and a `path`."} =
             run_tool_qa_file(task, %{"check" => "totals", "name" => "A number", "path" => 12}, [])
  end
end
