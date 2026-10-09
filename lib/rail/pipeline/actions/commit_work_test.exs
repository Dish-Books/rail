defmodule Rail.Pipeline.Actions.CommitWorkTest do
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

    # Review only takes a branch the remote has, so pushing here has to reach one.
    remote = create_temp_git_repo(prefix: "rail_git_remote", initial_commit: false)
    git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
    repo = create_temp_git_repo()
    git!(repo, ["remote", "add", "origin", remote])
    git!(repo, ["push", "--set-upstream", "origin", "main"])

    {:ok, task} = Pipeline.update_task(task, %{worktree_path: repo})
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

    # Going on to Review starts the Review lead.
    stub(Tools, :start_os_process, fn spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        conversation_id: "sess_commit_work",
        started_at: DateTime.utc_now()
      })

    %{issue: issue, scope: scope, project: project, run: run, task: task, repo: repo}
  end

  describe "at Engineer" do
    test "commits under the message it is handed, with the trailers naming the ticket and Rail", %{
      scope: scope,
      run: run,
      repo: repo
    } do
      File.write!(Path.join(repo, "feature.ex"), "one\n")

      assert {:ok, %Run{}} =
               Pipeline.commit_work(scope, run, %{
                 message: "CMW-1: add the vendor filter\n\nFilters invoices by vendor.\n"
               })

      message = git!(repo, ["log", "-1", "--pretty=%B"])
      assert message =~ "CMW-1: add the vendor filter"
      assert message =~ "Filters invoices by vendor."
      assert message =~ "Ticket: CMW-1 https://linear.app/rail/issue/CMW-1"
      assert message =~ "Co-Authored-By: Rail <rail[bot]@railai.dev>"
      refute message =~ "Rail-Step"
    end

    # The human pressed the button, so nobody wrote the message. A file an engineer
    # wrote before commits were handed over by tool is never read.
    test "falls back to a subject naming the ticket when no message is given", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      File.write!(Path.join(repo, "feature.ex"), "one\n")
      File.mkdir_p!(Path.join(task.scratch_path, "commits"))
      File.write!(Path.join([task.scratch_path, "commits", "CMW-1.md"]), "CMW-1: an old message\n")

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
      assert git!(repo, ["log", "-1", "--pretty=%s"]) =~ "CMW-1: follow-up changes"
    end

    test "with no CI, the pushed commit goes on to review", %{scope: scope, run: run, task: task, repo: repo} do
      File.write!(Path.join(repo, "feature.ex"), "one\n")
      {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})

      assert {:ok, %Run{stage_outcome: :done}} = Pipeline.commit_work(scope, run)
      refute Git.branch_unpushed?(repo)
      assert %Task{stage: :review} = Repo.reload!(task)
      assert %Run{stage_outcome: :done, review_on_ci_pass: false, error: nil} = Repo.reload!(run)
    end

    test "a clean worktree commits nothing and still sends the branch on", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      commits = git!(repo, ["rev-list", "--count", "HEAD"])

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
      assert git!(repo, ["rev-list", "--count", "HEAD"]) == commits
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    # A push that failed left a commit made and never sent. Running again has
    # nothing to commit and everything still to push, which is what the button offers.
    test "a push that failed sends nothing on and drops the go-ahead, and running again only pushes", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      File.write!(Path.join(repo, "feature.ex"), "one\n")
      stub(Git, :push_branch, fn _scope, _task -> {:error, "remote rejected"} end)

      assert {:error, "remote rejected"} = Pipeline.commit_work(scope, run, %{message: "CMW-1: add the vendor filter"})
      assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
      commits = git!(repo, ["rev-list", "--count", "HEAD"])

      stub(Git, :push_branch, fn _scope, %Task{worktree_path: path} ->
        git!(path, ["push", "origin", "HEAD"])
        :ok
      end)

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
      assert git!(repo, ["rev-list", "--count", "HEAD"]) == commits
      assert %Task{stage: :review} = Repo.reload!(task)
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
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: review_role.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      {:ok, run} = Pipeline.update_run(run, %{error: "CI passed, but the branch could not be pushed: rejected"})
      File.write!(Path.join(repo, "feature.ex"), "one\n")

      assert {:error, :stage_running} = Pipeline.commit_work(scope, run)
      refute Git.branch_unpushed?(repo)
      assert %Run{error: nil} = Repo.reload!(run)
      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    # Once Engineer hands the branch on it is Review's, and the Review lead commits its fixes.
    test "the engineer's commit on a task at Review is refused, with nothing committed and no go-ahead left", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
      File.write!(Path.join(repo, "feature.ex"), "one\n")
      reject(&Git.commit_worktree/3)
      reject(&Git.push_branch/2)

      assert {:error, {:invalid_stage, :review}} = Pipeline.commit_work(scope, run, %{message: "CMW-1: add it"})
      assert %Run{review_on_ci_pass: false} = Repo.reload!(run)
      assert %Task{stage: :review} = Repo.reload!(task)
    end

    # The diff pane can hold a run whose task it loaded before someone else sent it on.
    test "a commit from a page that still thinks the task is at engineer is refused", %{
      scope: scope,
      run: run,
      task: task,
      repo: repo
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :review})
      File.write!(Path.join(repo, "feature.ex"), "one\n")
      reject(&Git.commit_worktree/3)

      assert {:error, {:invalid_stage, :review}} = Pipeline.commit_work(scope, %{run | task: task})
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

      assert {:ok, %Run{status: :running, review_on_ci_pass: true}} =
               Pipeline.commit_work(scope, run, %{message: "CMW-1: add the vendor filter"})

      assert %Task{stage: :engineer} = Repo.reload!(task)
    end

    test "a commit CI already passed is pushed without running CI again, and goes on to review", %{
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
        stream_path: "/tmp/cmw-ci.log",
        status: :finished,
        started_at: DateTime.utc_now()
      })
      |> Repo.insert!()

      reject(Tools, :start_command_process, 4)

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
      refute Git.branch_unpushed?(repo)
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

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)

      assert %Task{pr_number: 12, pr_url: "https://github.com/example/test-seed/pull/12", pr_is_draft: true} =
               Repo.reload!(task)
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

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
      assert %Task{pr_number: 9, pr_is_draft: false} = Repo.reload!(task)
    end

    test "a task that has its pull request does not ask GitHub again", %{scope: scope, run: run, task: task} do
      {:ok, _opened} = Pipeline.update_task(task, %{pr_number: 5, pr_url: "https://github.com/example/test-seed/pull/5"})
      Req.Test.stub(Client, fn _conn -> flunk("asked GitHub about a pull request the task already has") end)

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
    end

    test "a pull request that cannot be opened is said in the run's log, and the push still stands", %{
      scope: scope,
      task: task,
      run: %Run{id: run_id} = run
    } do
      Req.Test.expect(Client, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end)

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
      assert %Task{pr_number: nil, stage: :review} = Repo.reload!(task)

      assert [%RunEvent{line: "[rail] Could not open the pull request: " <> _reason}] =
               RunEvent |> where(run_id: ^run_id) |> Repo.all()
    end

    test "the pull request is opened as the ticket's owner", %{scope: scope, run: run, task: task, issue: issue} do
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

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
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
          github_token: "gho_bo"
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

      assert {:ok, %Run{}} = Pipeline.commit_work(scope, run)
      assert %Task{pr_number: 22} = Repo.reload!(task)
    end
  end

  describe "at Review" do
    setup %{project: project, task: task} do
      {:ok, task} = Pipeline.update_task(task, %{stage: :review, pr_number: 7})
      {:ok, %{round: 1}} = Pipeline.save_review(task)
      {:ok, role} = Roles.get_role(project_id: project.id, stage: :review_lead)

      {:ok, lead_run} =
        Pipeline.create_run(%{
          task_id: task.id,
          role_id: role.id,
          status: :finished,
          stage_outcome: :done,
          conversation_id: "sess_commit_work_lead",
          started_at: DateTime.utc_now()
        })

      %{task: task, lead_run: lead_run}
    end

    test "the lead's commit is labeled its fix round, pushed, and starts the next round", %{
      scope: scope,
      task: task,
      lead_run: %Run{id: lead_run_id} = lead_run,
      repo: repo
    } do
      File.write!(Path.join(repo, "feature.ex"), "fixed\n")
      test_pid = self()

      expect(Tools, :start_os_process, fn %Run{id: ^lead_run_id} = spawned, _argv ->
        send(test_pid, :resumed)
        {:ok, %OsProcess{run: spawned}}
      end)

      assert {:ok, %Run{id: ^lead_run_id, stage_outcome: :in_progress}} =
               Pipeline.commit_work(scope, lead_run, %{message: "Guard the nil"})

      assert git!(repo, ["log", "-1", "--pretty=%B"]) =~ ~r/\AGuard the nil\n\nTicket: CMW-1 .*\nRail-Step: Fix round 1\n/
      refute Git.branch_unpushed?(repo)
      assert_received :resumed
      assert %Task{stage: :review} = Repo.reload!(task)

      assert ["[rail] Round 2 started after it was pushed"] =
               lead_run |> Pipeline.list_run_events() |> Enum.map(& &1.line)
    end

    test "with CI, the lead's commit runs CI on its run, and CI passing starts the next round", %{
      scope: scope,
      project: project,
      task: task,
      lead_run: %Run{id: lead_run_id} = lead_run,
      repo: repo
    } do
      {:ok, _project} = Projects.update_project(scope, project, %{ci_command: "mise run ci"})
      File.write!(Path.join(repo, "feature.ex"), "fixed\n")
      stub(Git, :credential_env, fn _project -> {:ok, %{}} end)

      expect(Tools, :start_command_process, fn %Run{id: ^lead_run_id} = spawned, :ci, "mise run ci", _opts ->
        {:ok, _running} = Pipeline.update_run(spawned, %{status: :running})
        {:ok, %OsProcess{kind: :ci, run: spawned}}
      end)

      assert {:ok, %Run{status: :running, review_on_ci_pass: true}} =
               Pipeline.commit_work(scope, lead_run, %{message: "Guard the nil"})

      # CI holds the push, and the round, until it passes.
      assert Git.branch_unpushed?(repo)
      assert [] = Pipeline.list_run_events(lead_run)
      head = String.trim(git!(repo, ["rev-parse", "HEAD"]))

      ci =
        %OsProcess{}
        |> OsProcess.changeset(%{
          run_id: lead_run_id,
          task_id: task.id,
          kind: :ci,
          head_sha: head,
          stream_path: "/tmp/cmw-lead-ci.log",
          status: :running,
          started_at: DateTime.utc_now()
        })
        |> Repo.insert!()

      expect(Tools, :start_os_process, fn %Run{id: ^lead_run_id} = spawned, _argv -> {:ok, %OsProcess{run: spawned}} end)

      assert {:ok, %Run{review_on_ci_pass: false, error: nil}} = Pipeline.run_finished(ci, %{exit_code: 0})
      refute Git.branch_unpushed?(repo)
      assert %Task{stage: :review} = Repo.reload!(task)

      assert ["[rail] Round 2 started after CI passed on " <> short] =
               lead_run |> Pipeline.list_run_events() |> Enum.map(& &1.line)

      assert String.starts_with?(head, short)
    end

    test "with dispatch off, the lead's commit is pushed and says the round was not started", %{
      scope: scope,
      lead_run: lead_run,
      repo: repo
    } do
      File.write!(Path.join(repo, "feature.ex"), "fixed\n")
      expect(Tools, :start_os_process, fn _spawned, _argv -> {:error, :dispatch_disabled} end)

      assert {:error, "Dispatch is off, so round 2 was not started."} =
               Pipeline.commit_work(scope, lead_run, %{message: "Guard the nil"})

      refute Git.branch_unpushed?(repo)
    end

    test "the lead's commit on a task back at Engineer is refused, with nothing committed", %{
      scope: scope,
      task: task,
      lead_run: lead_run,
      repo: repo
    } do
      {:ok, _moved} = Pipeline.update_task(task, %{stage: :engineer})
      File.write!(Path.join(repo, "feature.ex"), "fixed\n")
      reject(&Git.commit_worktree/3)
      reject(&Git.push_branch/2)

      assert {:error, {:invalid_stage, :engineer}} = Pipeline.commit_work(scope, lead_run, %{message: "Guard the nil"})
    end
  end
end
