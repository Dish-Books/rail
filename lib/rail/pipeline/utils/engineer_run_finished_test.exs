defmodule Rail.Pipeline.Utils.EngineerRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.EngineerRunFinished

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles

  setup %{project: project} do
    scope = system_scope()

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_efn_1", "identifier" => "EFN-1", "title" => "Engineer Finished"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Engineer Finished"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    worktree_path = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_engineer_finished",
        started_at: DateTime.utc_now()
      })

    %{
      task: task,
      run: Repo.preload(run, [:task, :role]),
      worktree_path: worktree_path
    }
  end

  # A turn that called `commit` was stopped and never reaches here, so one that
  # does ended on its own with the work still in the worktree.
  test "a turn that ended without calling commit records that and commits nothing", %{
    task: task,
    run: run,
    worktree_path: repo
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    reject(&Git.commit_worktree/3)

    assert %Run{error: "The engineer did not commit its work."} = engineer_run_finished(run, [])
    assert %Task{stage: :engineer} = Repo.reload!(task)
    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "initial commit"
  end
end
