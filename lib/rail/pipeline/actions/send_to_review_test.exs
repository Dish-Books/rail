defmodule Rail.Pipeline.Actions.SendToReviewTest do
  use Rail.DataCase, async: true

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
        name: "Send To Review Project",
        github_repo: "org/send-to-review",
        github_installation_id: 47_013,
        linear_workspace: %{
          name: "Send To Review Workspace",
          external_id: "lin_ws_send_to_review",
          token: "lin_api_token_send_to_review",
          webhook_secret: "whsec_send_to_review"
        },
        linear_team_key: "STR",
        default_branch: "main",
        clone_path: "/tmp/repos/send-to-review",
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
            "issue" => %{"id" => "lin_str_1", "identifier" => "STR-1", "title" => "Send To Review"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Send To Review"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    # A branch review can read is a branch the remote has, so the worktree here is
    # one that has actually been pushed.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])

    worktree_path = create_temp_git_repo()
    git!(worktree_path, ["remote", "add", "origin", remote])
    git!(worktree_path, ["push", "--set-upstream", "origin", "main"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree_path})
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :in_progress,
        conversation_id: "sess_send_to_review",
        started_at: DateTime.utc_now()
      })

    %{project: project, task: task, run: Repo.preload(run, [:task, :role]), worktree_path: worktree_path}
  end

  test "hands the task to review and latches the engineer run", %{task: task, run: run} do
    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.send_to_review(run)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "refuses work nobody has committed", %{task: task, run: run, worktree_path: repo} do
    File.write!(Path.join(repo, "uncommitted.ex"), "one\n")

    assert {:error, :uncommitted_changes} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # A commit nobody else can see is not a change anyone can review.
  test "refuses commits the remote has never been told about", %{task: task, run: run, worktree_path: repo} do
    File.write!(Path.join(repo, "local.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "never pushed"])

    assert {:error, :unpushed_changes} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses while something is still running on the task", %{task: task, run: run} do
    {:ok, _running} = Pipeline.update_run(run, %{status: :running})

    assert {:error, :stage_running} = Pipeline.send_to_review(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "refuses a task that is not at engineer", %{task: task, run: run} do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :architect})

    assert {:error, {:invalid_stage, :architect}} = Pipeline.send_to_review(run)
  end
end
