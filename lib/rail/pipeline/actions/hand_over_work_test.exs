defmodule Rail.Pipeline.Actions.HandOverWorkTest do
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
              "id" => "lin_hand_over_work_1",
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
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    # Git is only ever asked through Rail.Git, so the worktree is a plain directory the stubs answer from: it holds
    # an `unpushed` file while the branch has a commit the remote does not, and a push removes it. It starts with the
    # engineer's one commit not yet pushed, on the commit whose sha is all a's, up to date with main.
    repo = Path.join(task.scratch_path, "worktree")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "unpushed"), "")
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})

    stub(Git, :branch_unpushed?, fn path -> File.exists?(Path.join(path, "unpushed")) end)

    stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
      File.rm!(Path.join(path, "unpushed"))
      :ok
    end)

    stub(Git, :branch_fingerprint, fn _path ->
      %{head_sha: String.duplicate("a", 40), dirty_digest: String.duplicate("0", 64)}
    end)

    stub(Git, :base_status, fn _path, "main" -> %{behind: false, conflicts: []} end)

    # The check fetches with a token of its own, which the pull request tests would count.
    stub(Git, :check_push, fn _task -> :ok end)

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

    # Going on to Review starts QA and the code reviewer.
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_hand_over_work",
        started_at: DateTime.utc_now()
      })

    %{issue: issue, scope: scope, project: project, run: run, task: task, repo: repo}
  end

  describe "at Engineer" do
    test "with no CI, the pushed commit goes on to review", %{scope: scope, run: run, task: %Task{id: task_id} = task} do
      {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})

      expect(Git, :push_branch, fn ^scope, %Task{id: ^task_id, worktree_path: path} ->
        File.rm!(Path.join(path, "unpushed"))
        :ok
      end)

      assert {:ok, %Run{stage_outcome: :done}} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :review} = Repo.reload!(task)
      assert %Run{stage_outcome: :done, review_on_ci_pass: false, error: nil} = Repo.reload!(run)
    end

    # Work left uncommitted is not handed over: the agent commits what is finished, so only commits are asked about.
    test "a branch with nothing unpushed is refused with nothing sent", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      File.rm!(Path.join(repo, "unpushed"))
      reject(&Git.push_branch/2)

      assert {:error, :nothing_to_send} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    # Rail never force-pushes, so a branch that rewrote what it pushed is refused before CI or a push.
    test "a branch that rewrote commits already pushed is refused, with nothing pushed", %{
      scope: scope,
      run: run,
      task: %Task{id: task_id} = task
    } do
      expect(Git, :check_push, fn %Task{id: ^task_id} -> {:error, :history_rewritten} end)
      reject(&Git.push_branch/2)

      assert {:error, :history_rewritten} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    # A push that failed left a commit never sent, which is what the button offers again.
    test "a push that failed sends nothing on and drops the go-ahead, and running again pushes", %{
      scope: scope,
      run: run,
      task: task
    } do
      expect(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

      assert {:error, "remote rejected"} = Pipeline.hand_over_work(scope, run)
      assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)

      expect(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        File.rm!(Path.join(path, "unpushed"))
        :ok
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "a push review would still refuse leaves the task in engineer, pushed", %{
      scope: scope,
      project: project,
      run: run,
      task: %Task{id: task_id} = task
    } do
      {:ok, review_role} = Roles.get_role(project_id: project.id, stage: :review)

      {:ok, _working} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: review_role.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})
      expect(Git, :push_branch, fn ^scope, %Task{id: ^task_id} -> :ok end)

      assert {:error, :stage_running} = Pipeline.hand_over_work(scope, run)
      assert %Run{error: nil} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    # Once Engineer hands the branch on it is Review's, and the next round's engineer hands its fixes on. The diff
    # pane can hold a run whose task it loaded before someone else sent it on.
    test "the engineer's hand-over on a task at Review is refused, with nothing pushed and no go-ahead left, even from a page that still thinks the task is at engineer",
         %{scope: scope, run: run, task: task} do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
      reject(&Git.push_branch/2)

      assert {:error, {:invalid_stage, :review}} = Pipeline.hand_over_work(scope, run)
      assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :review} = Repo.reload!(task)

      assert {:error, {:invalid_stage, :review}} = Pipeline.hand_over_work(scope, %{run | task: task})
    end

    test "with CI, the commit waits on CI, holding the go-ahead for when it passes", %{
      scope: scope,
      project: project,
      run: run,
      task: task
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})

      reject(&Git.push_branch/2)
      stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

      expect(Tools, :start_command_process, fn spawned, :ci, "mise run ci", _opts ->
        {:ok, %OsProcess{kind: :ci, run: spawned}}
      end)

      assert {:ok, %Run{status: :running, review_on_ci_pass: true}} =
               Pipeline.hand_over_work(scope, run)

      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "with CI that cannot start, says why and drops the go-ahead", %{
      scope: scope,
      project: project,
      run: run,
      task: task
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
      stub(Git, :credential_env, fn _project -> {:error, {:github_api_error, 401, %{}}} end)
      reject(&Git.push_branch/2)

      assert {:error, "Could not start CI: {:github_api_error, 401, %{}}"} = Pipeline.hand_over_work(scope, run)
      assert %Run{status: :finished, review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a commit CI already passed is pushed without running CI again, and goes on to review", %{
      scope: scope,
      project: project,
      run: run,
      task: %Task{id: task_id} = task
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})

      %OsProcess{}
      |> OsProcess.changeset(%{
        run_id: run.id,
        task_id: task.id,
        kind: :ci,
        exit_code: 0,
        head_sha: String.duplicate("a", 40),
        stream_path: "/tmp/cmw-ci.log",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      reject(Tools, :start_command_process, 4)

      expect(Git, :push_branch, fn ^scope, %Task{id: ^task_id, worktree_path: path} ->
        File.rm!(Path.join(path, "unpushed"))
        :ok
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    test "the first push opens the task's pull request as a draft, and keeps it", %{scope: scope, run: run, task: task} do
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
                     "body" =>
                       "Closes CMW-1\n\nhttps://linear.app/rail/issue/CMW-1\n\nOpened by Rail as a draft." <> _rest
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

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)

      assert %Task{pr_number: 12, pr_url: "https://github.com/example/test-seed/pull/12", pr_is_draft: true} =
               Repo.reload!(task)
    end

    test "a GitHub issue's pull request closes it on merge", %{scope: scope, repo: repo, github_project: project} do
      issue = github_issue(project, %{number: 31, url: "https://github.com/example/test-gh/issues/31"})
      {:ok, task} = Pipeline.create_task(issue, :engineer)
      {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
      on_exit(fn -> File.rm_rf(task.scratch_path) end)

      {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

      {:ok, run} =
        Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

      Req.Test.expect(Client, 3, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-gh/pulls"} ->
            Req.Test.json(conn, [])

          {"POST", "/repos/example/test-gh/pulls"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            assert %{"body" => "Closes #31\n\nhttps://github.com/example/test-gh/issues/31\n\nOpened by Rail" <> _rest} =
                     Jason.decode!(body)

            conn
            |> Plug.Conn.put_status(201)
            |> Req.Test.json(%{
              "number" => 13,
              "html_url" => "https://github.com/example/test-gh/pull/13",
              "draft" => true
            })
        end
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: 13} = Repo.reload!(task)
    end

    test "an open pull request already on the branch is adopted, not opened twice", %{scope: scope, run: run, task: task} do
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

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: 9, pr_is_draft: false} = Repo.reload!(task)
    end

    test "a task that has its pull request does not ask GitHub again", %{scope: scope, run: run, task: task} do
      {:ok, _opened} = Pipeline.update_task(task, %{pr_number: 5, pr_url: "https://github.com/example/test-seed/pull/5"})
      Req.Test.stub(Client, fn _conn -> flunk("asked GitHub about a pull request the task already has") end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
    end

    test "a pull request that cannot be opened is said in the run's log, and the push still stands", %{
      scope: scope,
      task: task,
      run: %Run{id: run_id} = run
    } do
      Req.Test.expect(Client, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: nil, stage: :review} = Repo.reload!(task)

      assert [%RunEvent{line: "[rail] Could not open the pull request: " <> _reason}] =
               RunEvent |> where(run_id: ^run_id) |> Repo.all()
    end

    test "the pull request is opened as the ticket's owner", %{scope: scope, run: run, task: task, issue: issue} do
      {:ok, owner} =
        %User{}
        |> User.changeset(%{
          github_id: "gh_cmw",
          login: "ada-hand-over-work",
          name: "Ada",
          email: "ada-hand-over-work@example.com",
          github_token: "gho_ada",
          github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
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

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: 21} = Repo.reload!(task)
    end

    test "an owner GitHub turns away has the pull request opened as the Rail app", %{
      scope: scope,
      run: run,
      task: task,
      issue: issue
    } do
      {:ok, owner} =
        %User{}
        |> User.changeset(%{
          github_id: "gh_cmw2",
          login: "bo",
          name: "Bo",
          email: "bo@example.com",
          github_token: "gho_bo",
          github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
        })
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

      assert {:ok, %Run{}} = Pipeline.hand_over_work(scope, run)
      assert %Task{pr_number: 22} = Repo.reload!(task)
    end
  end

  # Only the engineer commits, so nothing the review agent's run holds is sent on, whatever the stage.
  test "the review agent's hand-over is refused at Review and at Engineer, with nothing pushed", %{
    scope: scope,
    project: project,
    task: task
  } do
    {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, review_run} =
      Pipeline.create_run(%{task_id: task.id, role_id: role.id, status: :finished, started_at: DateTime.utc_now()})

    reject(&Git.push_branch/2)

    assert {:error, {:invalid_stage, :engineer}} = Pipeline.hand_over_work(scope, review_run)

    {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
    assert {:error, {:invalid_stage, :review}} = Pipeline.hand_over_work(scope, review_run)
  end
end
