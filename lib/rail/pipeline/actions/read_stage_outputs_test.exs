defmodule Rail.Pipeline.Actions.ReadStageOutputsTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_rso_1", "identifier" => "RSO-1", "title" => "Translation sync"}
          }
        }
      })
    end)

    stages = [
      %IssueStage{stage: :custom, name: "Missing strings", prompt: "List the keys."},
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Translation sync", stages: stages})
    {:ok, task} = Pipeline.create_task(issue, {:custom, "License check"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  test "outputs read back in the order the sequence runs them, each with its name and when it was saved", %{task: task} do
    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "All MIT."})
    {:ok, earlier} = Pipeline.update_task(task, %{custom_stage: "Missing strings"})
    {:ok, _saved} = Pipeline.save_stage_output(earlier, %{markdown: "12 keys."})

    assert [
             %{name: "Missing strings", position: 1, markdown: "12 keys.", saved_at: %DateTime{}},
             %{name: "License check", position: 4, markdown: "All MIT.", saved_at: %DateTime{}}
           ] = Pipeline.read_stage_outputs(task)
  end

  # The agent can write over its file by hand, so what it left there is untrusted.
  test "a file left empty or not UTF-8 reads as not saved", %{task: task} do
    path = Path.join([task.scratch_path, "stages", "4-license-check.md"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, <<0xFF, 0xFE, 0x00>>)
    assert [] = Pipeline.read_stage_outputs(task)

    File.write!(path, "\n  \n")
    assert [] = Pipeline.read_stage_outputs(task)
  end
end
