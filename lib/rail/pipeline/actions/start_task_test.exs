defmodule Rail.Pipeline.Actions.StartTaskTest do
  use Rail.DataCase, async: true

  import Ecto.Query

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Scope
  alias Rail.Tools
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Users

  @branch "michael/stk-1-hosts"

  # Pull request #212 as GitHub reads it back: open, from a branch of the project's own repository into main.
  @pull_request %{
    "number" => 212,
    "state" => "open",
    "merged" => false,
    "draft" => true,
    "html_url" => "https://github.com/example/test-seed/pull/212",
    "head" => %{"ref" => @branch, "repo" => %{"full_name" => "example/test-seed"}},
    "base" => %{"ref" => "main", "repo" => %{"full_name" => "example/test-seed"}}
  }

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_start_task",
        identifier: "STK-1",
        title: "Sandboxes page shows which host each sandbox runs on",
        description: "Each row names its host.",
        priority: :medium,
        estimate: 3,
        state: :todo
      })
      |> Repo.insert!()

    %{issue: issue}
  end

  describe "at Plan" do
    test "starts the task at Plan with one Plan run, and no product, design or architect run", %{
      project: project,
      issue: issue
    } do
      {:ok, %Role{id: role_id}} = Roles.get_role(project_id: project.id, stage: :plan)

      expect(Git, :get_or_create_worktree, fn _project, task -> {:ok, task.worktree_path} end)
      expect(Tools, :start_os_process, fn %Run{} = run, _argv -> {:ok, %OsProcess{task_id: run.task_id, run: run}} end)

      assert {:ok, %Task{id: task_id, stage: :plan, runs: [%Run{role_id: ^role_id}]}} =
               Pipeline.start_task(system_scope(), issue, :plan)

      assert [%Run{role_id: ^role_id}] = Repo.all(from r in Run, where: r.task_id == ^task_id)
    end

    # A tab still showing Start at after the task started elsewhere, even at Review, opens that task.
    test "opens the issue's task when it has one, starting no Plan run on it", %{issue: issue} do
      {:ok, %Task{id: task_id}} = Pipeline.create_task(Repo.preload(issue, :project), :review)
      reject(&Tools.start_os_process/2)

      assert {:ok, %Task{id: ^task_id, stage: :review, runs: []}} = Pipeline.start_task(system_scope(), issue, :plan)
    end

    test "says what failed to start", %{issue: issue} do
      expect(Git, :get_or_create_worktree, fn _project, _task -> {:error, "no checkout"} end)

      assert {:error, {:worktree_failed, "no checkout"}} = Pipeline.start_task(system_scope(), issue, :plan)
    end

    test "refuses someone who cannot open the issue's project", %{issue: issue} do
      reject(&Tools.start_os_process/2)

      assert {:error, :not_found} = Pipeline.start_task(user_scope(), issue, :plan)
      refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    end
  end

  describe "at Review" do
    setup %{project: project} do
      remote = create_temp_git_repo(prefix: "rail_start_review_remote")
      git!(remote, ["config", "receive.denyCurrentBranch", "ignore"])
      git!(remote, ["checkout", "--quiet", "-b", @branch])
      File.write!(Path.join(remote, "hosts.ex"), "built locally\n")
      git!(remote, ["add", "."])
      git!(remote, ["commit", "--quiet", "-m", "Name each sandbox's host"])
      head = remote |> git!(["rev-parse", "HEAD"]) |> String.trim()
      git!(remote, ["checkout", "--quiet", "main"])

      clone = Path.join(System.tmp_dir!(), "rail_start_review_clone_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(clone) end)
      git!(System.tmp_dir!(), ["clone", "--quiet", remote, clone])

      project = project |> Ecto.Changeset.change(clone_path: clone) |> Repo.update!()

      {:ok, %{id: user_id} = user} =
        Users.register_oauth_user(%{
          github_id: "gh_start_review",
          login: "michael",
          name: "Michael Gutierrez",
          email: "michael@example.com"
        })

      scope = Scope.for_user(%{user | project_ids: [project.id]})

      %{project: project, remote: remote, clone: clone, head: head, scope: scope, user_id: user_id}
    end

    test "takes the pull request over at Review on its branch as pushed, with QA and the code reviewer started", %{
      issue: issue,
      clone: clone,
      head: head,
      scope: scope,
      user_id: user_id
    } do
      pull_request = put_in(@pull_request, ["head", "sha"], head)

      Req.Test.stub(Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} -> Req.Test.json(conn, %{"token" => "ghs_token"})
          {"GET", "/repos/example/test-seed/pulls/212"} -> Req.Test.json(conn, pull_request)
        end
      end)

      test_pid = self()

      stub(Tools, :start_os_process, fn %Run{} = spawned, _argv ->
        send(test_pid, {:started, Repo.preload(spawned, :role, force: true).role.stage})
        {:ok, %OsProcess{run: spawned}}
      end)

      worktree = Path.join(clone, ".worktrees/#{@branch}")

      assert {:ok,
              %Task{
                id: task_id,
                stage: :review,
                worktree_name: @branch,
                worktree_path: ^worktree,
                pr_number: 212,
                pr_url: "https://github.com/example/test-seed/pull/212",
                pr_is_draft: true,
                submitted_by_id: ^user_id,
                submitted_at: %DateTime{},
                submitted_head: ^head
              }} = Pipeline.start_task(scope, issue, :review, "https://github.com/example/test-seed/pull/212/files")

      assert_received {:started, :qa}
      assert_received {:started, :review}
      refute_received {:started, _other}

      assert worktree |> git!(["rev-parse", "HEAD"]) |> String.trim() == head
      refute Git.branch_unpushed?(worktree)

      assert [
               %Round{
                 number: 1,
                 plan: nil,
                 approved_at: %DateTime{},
                 approved_by_id: ^user_id,
                 ticket: %Round.Ticket{
                   title: "Sandboxes page shows which host each sandbox runs on",
                   description: "Each row names its host.",
                   priority: :medium,
                   estimate: 3
                 }
               }
             ] = Repo.all(from r in Round, where: r.task_id == ^task_id)
    end

    test "opens the issue's task when it has one, asking GitHub nothing", %{issue: issue, scope: scope} do
      {:ok, %Task{id: task_id}} = Pipeline.create_task(Repo.preload(issue, :project), :plan)

      assert {:ok, %Task{id: ^task_id, stage: :plan}} = Pipeline.start_task(scope, issue, :review, "#212")
    end

    # Two tabs handing over at once both read the pull request; the second to insert opens the first's task.
    test "opens the task another tab started while GitHub was being asked", %{issue: issue, scope: scope} do
      Req.Test.stub(Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-seed/pulls/212"} ->
            {:ok, _first} = Pipeline.create_task(Repo.preload(issue, :project), :review)
            Req.Test.json(conn, @pull_request)
        end
      end)

      reject(&Tools.start_os_process/2)

      assert {:ok, %Task{id: task_id, stage: :review, pr_number: nil}} =
               Pipeline.start_task(scope, issue, :review, "#212")

      assert [%Task{id: ^task_id}] = Repo.all(from t in Task, where: t.issue_id == ^issue.id)
    end

    test "refuses what is not a pull request of the project's repository without asking GitHub", %{
      issue: issue,
      scope: scope
    } do
      assert {:error, :not_a_pull_request} = Pipeline.start_task(scope, issue, :review, "the host one")
      assert {:error, :not_a_pull_request} = Pipeline.start_task(scope, issue, :review, "")

      assert {:error, {:other_repository, "someone/else"}} =
               Pipeline.start_task(scope, issue, :review, "https://github.com/someone/else/pull/212")

      refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    end

    test "refuses, with the reason, a pull request Rail cannot take, and makes no task", %{
      project: project,
      issue: issue,
      scope: scope
    } do
      {:ok, other} =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_start_task_2",
          identifier: "STK-2",
          title: "Already on it",
          state: :todo
        })
        |> Repo.insert()

      {:ok, taken} = Pipeline.create_task(Repo.preload(other, :project), :review)
      {:ok, _taken} = Pipeline.update_task(taken, %{pr_number: 209})

      pulls = %{
        "198" => Map.merge(@pull_request, %{"number" => 198, "state" => "closed", "merged" => true}),
        "199" => Map.merge(@pull_request, %{"number" => 199, "state" => "closed"}),
        "207" =>
          Map.merge(@pull_request, %{
            "number" => 207,
            "head" => %{"ref" => "x", "repo" => %{"full_name" => "fork/test-seed"}}
          }),
        "208" => Map.merge(@pull_request, %{"number" => 208, "head" => %{"ref" => "x", "repo" => nil}}),
        "205" => Map.merge(@pull_request, %{"number" => 205, "base" => %{"ref" => "release/2026-10"}}),
        "209" => Map.put(@pull_request, "number", 209),
        "210" =>
          Map.merge(@pull_request, %{
            "number" => 210,
            "head" => %{"ref" => taken.worktree_name, "repo" => %{"full_name" => "Example/Test-Seed"}}
          })
      }

      Req.Test.stub(Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-seed/pulls/" <> number} when is_map_key(pulls, number) ->
            Req.Test.json(conn, pulls[number])

          {"GET", "/repos/example/test-seed/pulls/2120"} ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
        end
      end)

      reject(&Tools.start_os_process/2)

      assert {:error, {:no_pull_request, "example/test-seed", 2120}} = Pipeline.start_task(scope, issue, :review, "#2120")
      assert {:error, {:pull_request_merged, 198}} = Pipeline.start_task(scope, issue, :review, "198")
      assert {:error, {:pull_request_closed, 199}} = Pipeline.start_task(scope, issue, :review, "#199")
      assert {:error, {:pull_request_from_fork, 207}} = Pipeline.start_task(scope, issue, :review, "#207")
      assert {:error, {:pull_request_from_fork, 208}} = Pipeline.start_task(scope, issue, :review, "#208")

      assert {:error, {:pull_request_into, 205, "release/2026-10", "main"}} =
               Pipeline.start_task(scope, issue, :review, "#205")

      assert {:error, {:pull_request_taken, 209, "STK-2"}} = Pipeline.start_task(scope, issue, :review, "#209")
      assert {:error, {:pull_request_taken, 210, "STK-2"}} = Pipeline.start_task(scope, issue, :review, "#210")

      refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    end

    test "makes no task when the branch cannot be checked out", %{issue: issue, scope: scope} do
      Req.Test.stub(Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/app/installations/1/access_tokens"} ->
            Req.Test.json(conn, %{"token" => "ghs_token"})

          {"GET", "/repos/example/test-seed/pulls/212"} ->
            Req.Test.json(conn, put_in(@pull_request, ["head", "ref"], "gone"))
        end
      end)

      reject(&Tools.start_os_process/2)

      assert {:error, {:branch_failed, output}} = Pipeline.start_task(scope, issue, :review, "#212")
      assert output =~ "couldn't find remote ref"
      refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    end

    test "says so when GitHub cannot be asked, before or after the pull request is read, and makes no task", %{
      issue: issue,
      scope: scope
    } do
      token = &Req.Test.json(&1, %{"token" => "ghs_token"})
      down = &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "Down"}))

      Req.Test.expect(Client, token)
      Req.Test.expect(Client, down)
      assert {:error, {:github_api_error, 500, _body}} = Pipeline.start_task(scope, issue, :review, "#212")

      # The branch is fetched with a token of its own.
      Req.Test.expect(Client, token)
      Req.Test.expect(Client, &Req.Test.json(&1, @pull_request))
      Req.Test.expect(Client, down)
      assert {:error, {:github_api_error, 500, _body}} = Pipeline.start_task(scope, issue, :review, "#212")

      refute Repo.exists?(from t in Task, where: t.issue_id == ^issue.id)
    end

    test "refuses someone who cannot open the issue's project", %{issue: issue} do
      assert {:error, :not_found} = Pipeline.start_task(user_scope(), issue, :review, "#212")
    end
  end
end
