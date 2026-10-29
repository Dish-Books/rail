defmodule Rail.Pipeline.Actions.SaveStageOutputTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_sso_1", "identifier" => "SSO-1", "title" => "Dependency updates"}
          }
        }
      })
    end)

    stages = [
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each license."},
      %IssueStage{stage: :review}
    ]

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Dependency updates", stages: stages})
    {:ok, task} = Pipeline.create_task(issue, {:custom, "License check"})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{task: task}
  end

  test "an output is saved for the stage the task is at, and a second save replaces the first", %{
    task: %Task{id: task_id} = task
  } do
    assert {:ok, "## License check\n\nAll MIT."} =
             Pipeline.save_stage_output(task, %{markdown: "  ## License check\n\nAll MIT.\n\n"})

    assert_received {:output_saved, ^task_id}
    assert {:ok, "One is AGPL."} = Pipeline.save_stage_output(task, %{markdown: "One is AGPL."})
    assert [%{name: "License check", position: 3, markdown: "One is AGPL."}] = Pipeline.read_stage_outputs(task)
  end

  test "an empty output is refused and the last save stays", %{task: task} do
    {:ok, _saved} = Pipeline.save_stage_output(task, %{markdown: "All MIT."})

    assert {:error, :empty_output} = Pipeline.save_stage_output(task, %{markdown: " \n "})
    assert [%{markdown: "All MIT."}] = Pipeline.read_stage_outputs(task)
  end

  test "a save at any other stage is refused, so an approved file cannot change", %{task: task} do
    {:ok, reviewing} = Pipeline.update_task(task, %{stage: :review})

    assert {:error, {:invalid_stage, :review}} = Pipeline.save_stage_output(reviewing, %{markdown: "Late."})

    {:ok, renamed} = Pipeline.update_task(reviewing, %{stage: :custom, custom_stage: "Gone from the file"})
    assert {:error, {:invalid_stage, :custom}} = Pipeline.save_stage_output(renamed, %{markdown: "Late."})
    assert [] = Pipeline.read_stage_outputs(task)
  end
end
