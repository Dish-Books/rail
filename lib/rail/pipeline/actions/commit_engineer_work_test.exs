defmodule Rail.Pipeline.Actions.CommitEngineerWorkTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users.Schemas.User

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

  test "the first push opens the task's pull request as a draft, and keeps it", %{scope: scope, task: task} do
    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls"} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/example/test-seed/pulls"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert %{
                   "title" => "CMW-1 Invoice filters",
                   "head" => "cmw-1",
                   "base" => "main",
                   "draft" => true,
                   "body" => "https://linear.app/rail/issue/CMW-1\n\nOpened by Rail as a draft." <> _rest
                 } = Jason.decode!(body)

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => 12,
            "html_url" => "https://github.com/example/test-seed/pull/12",
            "draft" => true
          })
      end
    end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)

    assert %Task{pr_number: 12, pr_url: "https://github.com/example/test-seed/pull/12", pr_is_draft: true} =
             Repo.reload!(task)
  end

  test "an open pull request already on the branch is adopted, not opened twice", %{scope: scope, task: task} do
    Req.Test.expect(Client, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls"} ->
          Req.Test.json(conn, [
            %{"number" => 9, "html_url" => "https://github.com/example/test-seed/pull/9", "draft" => false}
          ])
      end
    end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert %Task{pr_number: 9, pr_is_draft: false} = Repo.reload!(task)
  end

  test "a task that has its pull request does not ask GitHub again", %{scope: scope, task: task} do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 5, pr_url: "https://github.com/example/test-seed/pull/5"})
    Req.Test.stub(Client, fn _conn -> flunk("asked GitHub about a pull request the task already has") end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
  end

  test "a pull request that cannot be opened is said in the run's log, and the push still stands", %{
    scope: scope,
    task: task,
    run: %Run{id: run_id}
  } do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert %Task{pr_number: nil} = Repo.reload!(task)
    assert [%RunEvent{run_id: ^run_id, line: "[rail] Could not open the pull request: " <> _reason}] = Repo.all(RunEvent)
  end

  test "the pull request is opened as the ticket's owner", %{scope: scope, task: task, issue: issue} do
    {:ok, owner} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_cmw",
        login: "ada",
        name: "Ada",
        email: "ada@example.com",
        github_token: "gho_ada"
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: owner.id})

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
        {"POST", "/app/installations/" <> _id, _auth} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", "/repos/example/test-seed/pulls", ["Bearer ghs_app"]} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/example/test-seed/pulls", ["Bearer gho_ada"]} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 21, "html_url" => "https://github.com/example/test-seed/pull/21"})
      end
    end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert %Task{pr_number: 21} = Repo.reload!(task)
  end

  test "an owner GitHub turns away has the pull request opened as the Rail app", %{
    scope: scope,
    task: task,
    issue: issue
  } do
    {:ok, owner} =
      %User{}
      |> User.changeset(%{github_id: "gh_cmw2", login: "bo", name: "Bo", email: "bo@example.com", github_token: "gho_bo"})
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: owner.id})

    Req.Test.expect(Client, 4, fn conn ->
      case {conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
        {"POST", "/app/installations/" <> _id, _auth} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", "/repos/example/test-seed/pulls", _auth} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/example/test-seed/pulls", ["Bearer gho_bo"]} ->
          conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "Resource not accessible"})

        {"POST", "/repos/example/test-seed/pulls", ["Bearer ghs_app"]} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 22, "html_url" => "https://github.com/example/test-seed/pull/22"})
      end
    end)

    assert :ok = Pipeline.commit_engineer_work(scope, task)
    assert %Task{pr_number: 22} = Repo.reload!(task)
  end
end
