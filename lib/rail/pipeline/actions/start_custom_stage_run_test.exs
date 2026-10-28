defmodule Rail.Pipeline.Actions.StartCustomStageRunTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_scsr_1", "identifier" => "SCSR-1", "title" => "Dependency updates"}
          }
        }
      })
    end)

    stages = [
      %IssueStage{stage: :custom, name: "Missing strings", prompt: "List the keys."},
      %IssueStage{stage: :plan},
      %IssueStage{stage: :engineer},
      %IssueStage{stage: :custom, name: "License check", prompt: "Check each changed dependency against LICENSES.md."},
      %IssueStage{stage: :review}
    ]

    {:ok, issue} =
      Issues.create_issue(system_scope(), project, %{
        title: "Dependency updates",
        description: "Update the dependencies.",
        stages: stages
      })

    {:ok, task} = Pipeline.create_task(issue, {:custom, "License check"})
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, role} = Roles.get_custom_stage_role(project.id, "License check")
    {:ok, %Role{model: model}} = Roles.get_role(project_id: project.id, stage: :engineer)
    {:ok, run} = Pipeline.start_or_resume_run(task, role, worktree_path)

    %{task: task, run: run, model: model}
  end

  test "spawns on Engineer's model with the issue's copy of its prompt, handed the plan and earlier stages' files", %{
    task: task,
    run: run,
    model: model
  } do
    Repo.insert!(%Round{
      task_id: task.id,
      number: 1,
      plan: "## Implementation plan\n\nBump req.",
      approved_at: DateTime.utc_now()
    })

    File.mkdir_p!(Path.join(task.scratch_path, "stages"))
    File.write!(Path.join([task.scratch_path, "stages", "1-missing-strings.md"]), "12 keys.\n")
    File.write!(Path.join([task.scratch_path, "stages", "4-license-check.md"]), "My own last save.\n")

    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt, "--model", ^model | _rest] = argv ->
      assert "Check each changed dependency against LICENSES.md." in argv
      assert prompt =~ "`save_stage_output`"
      assert prompt =~ "Bump req."
      assert prompt =~ ~s(<stage_output stage="Missing strings">\n12 keys.\n</stage_output>)
      refute prompt =~ "My own last save."
      assert prompt =~ "title: Dependency updates"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_custom_stage_run(run)
  end

  test "before Plan there is no plan to hand it", %{run: run} do
    expect(Tools, :start_os_process, fn %Run{} = spawned, ["-p", prompt | _rest] ->
      refute prompt =~ "The approved implementation plan"
      refute prompt =~ "<stage_output"
      {:ok, %OsProcess{run: spawned}}
    end)

    assert {:ok, %OsProcess{}} = Pipeline.start_custom_stage_run(run)
  end
end
