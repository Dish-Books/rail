defmodule Rail.Pipeline.Utils.EngineerRunFinishedTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.EngineerRunFinished

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools

  setup do
    scope = system_scope()

    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Engineer Finished Project",
        github_repo: "org/engineer-finished",
        github_installation_id: 47_012,
        linear_workspace: %{
          name: "Engineer Finished Workspace",
          external_id: "lin_ws_engineer_finished",
          token: "lin_api_token_engineer_finished",
          webhook_secret: "whsec_engineer_finished"
        },
        linear_team_key: "EFN",
        default_branch: "main",
        clone_path: "/tmp/repos/engineer-finished",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer agent."
      })

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
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :running,
        conversation_id: "sess_engineer_finished",
        started_at: DateTime.utc_now()
      })

    stub(Git, :push_branch, fn _scope, _task -> :ok end)

    Req.Test.stub(Rail.GitHub.Client, fn conn ->
      Req.Test.json(conn, %{"token" => "ghs_installation_token"})
    end)

    %{
      task: task,
      run: Repo.preload(run, [:task, :role]),
      worktree_path: worktree_path,
      message_path: Path.join(task.scratch_path, "commits/EFN-1.md")
    }
  end

  test "commits and pushes what the engineer left, and moves nothing", %{
    task: task,
    run: run,
    worktree_path: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "EFN-1: add the feature\n")

    assert %Run{error: nil} = engineer_run_finished(run, [])
    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "EFN-1: add the feature"
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a run that stopped without saying it was finished records that and waits", %{
    task: task,
    run: run,
    worktree_path: repo
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert %Run{error: "The engineer did not write commits/EFN-1.md."} = engineer_run_finished(run, [])
    assert %Task{stage: :engineer} = Repo.reload!(task)
    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "initial commit"
  end

  test "a run that said it was finished but changed nothing records that", %{
    run: run,
    message_path: message_path
  } do
    File.write!(message_path, "EFN-1: add the feature\n")

    assert %Run{error: "The engineer said it was done but changed nothing in the worktree."} =
             engineer_run_finished(run, [])
  end

  test "a commit git refused is recorded on the run", %{
    run: run,
    worktree_path: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "EFN-1: add the feature\n")

    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

    assert %Run{error: "Could not commit the engineer's work: remote rejected"} = engineer_run_finished(run, [])
  end

  test "a commit git refused for a reason of its own is spelled out on the run", %{
    run: run,
    worktree_path: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "EFN-1: add the feature\n")

    stub(Git, :commit_worktree, fn _scope, _task, _message -> {:error, :nothing_to_commit} end)

    assert %Run{error: "Could not commit the engineer's work: :nothing_to_commit"} = engineer_run_finished(run, [])
  end
end
