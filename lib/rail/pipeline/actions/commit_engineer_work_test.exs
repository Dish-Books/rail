defmodule Rail.Pipeline.Actions.CommitEngineerWorkTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(scope, %{
        name: "Commit Work Project",
        github_repo: "org/commit-work",
        github_installation_id: 47_011,
        linear_workspace: %{
          name: "Commit Work Workspace",
          external_id: "lin_ws_commit_work",
          token: "lin_api_token_commit_work",
          webhook_secret: "whsec_commit_work"
        },
        linear_team_key: "CMW",
        default_branch: "main",
        clone_path: "/tmp/repos/commit-work",
        linear_state_ids: %{"triage" => "st_triage"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_commit_work_1",
              "identifier" => "CMW-1",
              "title" => "Invoice filters",
              "url" => "https://linear.app/rail/issue/CMW-1"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Invoice filters"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)
    repo = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    stub(Git, :push_branch, fn _scope, _task -> :ok end)

    # A project with CI runs it on the engineer's run.
    {:ok, backend} = Tools.create_backend(scope, %{name: :claude, executable_path: "/usr/bin/true"})

    {:ok, role} =
      Roles.create_role(scope, project, %{
        backend_id: backend.id,
        stage: :engineer,
        name: "engineer role",
        model: "claude-3-7-sonnet",
        system_prompt: "You are the engineer."
      })

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    %{
      run: run,
      scope: scope,
      project: project,
      task: task,
      repo: repo,
      message_path: Path.join(task.scratch_path, "commits/CMW-1.md")
    }
  end

  test "commits what the engineer wrote, under the trailers naming the ticket and Rail", %{
    scope: scope,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n\nFilters invoices by vendor.\n")

    assert :ok = Pipeline.commit_engineer_work(scope, task)

    message = git!(repo, ["log", "-1", "--pretty=%B"])
    assert message =~ "CMW-1: add the vendor filter"
    assert message =~ "Filters invoices by vendor."
    assert message =~ "Ticket: CMW-1 https://linear.app/rail/issue/CMW-1"
    assert message =~ "Co-Authored-By: Rail <rail[bot]@railai.dev>"
  end

  # This is the Commit button: the human asked for it, so there is no written
  # message to use.
  test "falls back to a subject naming the ticket when nothing was written", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "CMW-1: follow-up changes"
  end

  # The file being gone is what makes its absence mean something next round.
  test "drops the message file once the commit exists", %{
    scope: scope,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n")

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    refute File.exists?(message_path)
  end

  test "keeps the message file when the push failed", %{
    scope: scope,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n")

    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

    assert {:error, "remote rejected"} = Pipeline.commit_engineer_work(scope, task)
    assert File.exists?(message_path)
  end

  # A push that failed left a commit made and never sent. Running again has
  # nothing to commit and everything still to push, which is what the button
  # offers after a failure: the same call, finishing what is outstanding.
  test "pushes again without committing again when only the push failed", %{
    scope: scope,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n")

    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)
    assert {:error, "remote rejected"} = Pipeline.commit_engineer_work(scope, task)

    commits = git!(repo, ["rev-list", "--count", "HEAD"])

    stub(Git, :push_branch, fn _scope, _task -> :ok end)
    assert :ok = Pipeline.commit_engineer_work(scope, task)

    assert git!(repo, ["rev-list", "--count", "HEAD"]) == commits
    refute File.exists?(message_path)
  end

  test "a clean worktree with nothing left to push is still nothing to do", %{scope: scope, task: task} do
    assert :ok = Pipeline.commit_engineer_work(scope, task)
  end

  test "a project with CI runs it on the commit instead of pushing it", %{
    scope: scope,
    project: project,
    run: run,
    task: task,
    repo: repo,
    message_path: message_path
  } do
    {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    File.write!(message_path, "CMW-1: add the vendor filter\n")

    reject(&Git.push_branch/2)
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    refute File.exists?(message_path)
    assert %Run{status: :running} = Repo.reload!(run)
  end

  test "a commit CI has already passed is pushed without running CI again", %{
    scope: scope,
    project: project,
    run: run,
    task: task,
    repo: repo
  } do
    {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: task.id,
      kind: :ci,
      exit_code: 0,
      head_sha: String.trim(git!(repo, ["rev-parse", "HEAD"])),
      stream_path: "/tmp/cmw-ci.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    reject(Tools, :start_command_process, 4)
    expect(Git, :push_branch, fn _scope, _task -> :ok end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
  end
end
