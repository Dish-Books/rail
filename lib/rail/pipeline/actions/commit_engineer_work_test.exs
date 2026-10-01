defmodule Rail.Pipeline.Actions.CommitEngineerWorkTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Git
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.OpenPullRequest
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess

  setup %{project: project} do
    scope = system_scope()

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

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    %{
      issue: issue,
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

  test "a commit on a task past engineer sends it back to engineer", %{scope: scope, task: task, repo: repo} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa})
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # The diff pane can hold a task loaded before someone else sent it on.
  test "a commit from a page that still thinks the task is at engineer sends it back", %{
    scope: scope,
    task: task,
    repo: repo
  } do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :qa})
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert :ok = Pipeline.commit_engineer_work(scope, %{task | stage: :engineer})
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # A retry with only the push outstanding changes no code, so nothing new needs review.
  test "a push with nothing to commit leaves a task past engineer where it is", %{scope: scope, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{stage: :qa})

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert %Task{stage: :qa} = Repo.reload!(task)
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

  test "a push queues the job that opens and describes the task's pull request", %{scope: scope, task: task} do
    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert_enqueued(worker: OpenPullRequest, args: %{task_id: task.id})
  end

  test "a push that fails queues no pull request", %{scope: scope, task: task, repo: repo} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

    assert {:error, "remote rejected"} = Pipeline.commit_engineer_work(scope, task)
    refute_enqueued(worker: OpenPullRequest)
  end

  # Later pushes never describe it again, a limitation the ticket keeps.
  test "a task that has its pull request queues nothing", %{scope: scope, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 5, pr_url: "https://github.com/example/test-seed/pull/5"})

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    refute_enqueued(worker: OpenPullRequest)
  end

  test "a project with CI that only started CI queues no pull request", %{
    scope: scope,
    project: project,
    task: task,
    repo: repo
  } do
    {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    refute_enqueued(worker: OpenPullRequest)
  end
end
