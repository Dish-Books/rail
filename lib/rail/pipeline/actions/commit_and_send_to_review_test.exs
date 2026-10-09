defmodule Rail.Pipeline.Actions.CommitAndSendToReviewTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
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
              "id" => "lin_commit_review_1",
              "identifier" => "CSR-1",
              "title" => "Invoice filters",
              "url" => "https://linear.app/rail/issue/CSR-1"
            }
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Invoice filters"})
    {:ok, task} = Pipeline.create_task(issue, :engineer)

    # Review only takes a branch the remote has, so pushing here has to reach one.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "--set-upstream", "origin", "main"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
    File.mkdir_p!(Path.join(task.scratch_path, "commits"))
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
      git!(path, ["push", "origin", "HEAD"])
      :ok
    end)

    # Every push opens the task's pull request if it has none.
    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", _pulls} ->
          Req.Test.json(conn, [])

        {"POST", _pulls} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 7, "html_url" => "https://github.com/org/repo/pull/7", "draft" => true})
      end
    end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_commit_and_send_to_review",
        started_at: DateTime.utc_now()
      })

    %{scope: scope, project: project, run: run, task: task, repo: repo}
  end

  test "with no CI, the pushed commit goes on to review", %{scope: scope, run: run, task: task, repo: repo} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})

    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{stage_outcome: :done}} = Pipeline.commit_and_send_to_review(scope, run)
    assert %Task{stage: :review} = Repo.reload!(task)
    assert %Run{stage_outcome: :done, review_on_ci_pass: false, error: nil} = Repo.reload!(run)
  end

  # The human pressed the button, so nobody wrote the message.
  test "the human's commit is made under the follow-up subject", %{scope: scope, run: run, repo: repo} do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{}} = Pipeline.commit_and_send_to_review(scope, run)
    assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ ": follow-up changes"
  end

  test "with CI, the commit waits on CI, holding the go-ahead for when it passes", %{
    scope: scope,
    project: project,
    run: run,
    task: task,
    repo: repo
  } do
    {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    reject(&Git.push_branch/2)
    stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

    expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
      {:ok, %OsProcess{kind: :ci, run: spawned}}
    end)

    assert {:ok, %Run{status: :running, review_on_ci_pass: true}} = Pipeline.commit_and_send_to_review(scope, run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a commit CI already passed is pushed and goes on to review", %{
    scope: scope,
    project: project,
    run: run,
    task: task,
    repo: repo
  } do
    {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", "never pushed"])

    %OsProcess{}
    |> OsProcess.changeset(%{
      run_id: run.id,
      task_id: task.id,
      kind: :ci,
      exit_code: 0,
      head_sha: String.trim(git!(repo, ["rev-parse", "HEAD"])),
      stream_path: "/tmp/csr-ci.log",
      status: :finished,
      started_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    reject(Tools, :start_command_process, 4)
    expect(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    assert {:ok, %Run{}} = Pipeline.commit_and_send_to_review(scope, run)
    refute Git.branch_unpushed?(repo)
    assert %Task{stage: :review} = Repo.reload!(task)
  end

  test "a push that failed sends nothing on and drops the go-ahead", %{
    scope: scope,
    run: run,
    task: task,
    repo: repo
  } do
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

    assert {:error, "remote rejected"} = Pipeline.commit_and_send_to_review(scope, run)
    assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  test "a push review would still refuse leaves the task in engineer, pushed", %{
    scope: scope,
    project: project,
    run: run,
    task: task,
    repo: repo
  } do
    {:ok, review_role} = Roles.get_role(project_id: project.id, stage: :review)

    {:ok, _working} =
      Pipeline.create_run(%{task_id: task.id, role_id: review_role.id, status: :running, started_at: DateTime.utc_now()})

    {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})
    File.write!(Path.join(repo, "feature.ex"), "one\n")

    assert {:error, :stage_running} = Pipeline.commit_and_send_to_review(scope, run)
    refute Git.branch_unpushed?(repo)
    assert %Run{error: nil} = Repo.reload!(run)
    assert %Task{stage: :engineer} = Repo.reload!(task)
  end

  # Past Engineer the branch is Review's, and its fixes are committed by the Review lead.
  test "a task past engineer is refused, with nothing committed and no go-ahead left", %{
    scope: scope,
    run: run,
    task: task,
    repo: repo
  } do
    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
    File.write!(Path.join(repo, "feature.ex"), "one\n")
    reject(&Git.commit_worktree/3)

    assert {:error, {:invalid_stage, :review}} = Pipeline.commit_and_send_to_review(scope, run, "CSR-1: add it")
    assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
  end
end
