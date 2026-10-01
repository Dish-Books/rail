defmodule Rail.Pipeline.Workers.OpenPullRequestTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.RunEvent
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Pipeline.Workers.OpenPullRequest
  alias Rail.Roles
  alias Rail.Tools
  alias Rail.Users.Schemas.User

  setup {Req.Test, :verify_on_exit!}

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_opr",
        identifier: "OPR-1",
        title: "Invoice filters",
        url: "https://linear.app/rail/issue/OPR-1",
        state: :in_progress
      })
      |> Repo.insert!()

    task =
      %Task{}
      |> Task.changeset(
        %{
          issue_id: issue.id,
          stage: :engineer,
          worktree_name: "opr-1",
          worktree_path: "/tmp/repos/test-seed/.worktrees/opr-1",
          scratch_path: Path.join(System.tmp_dir!(), "open_pr_#{System.unique_integer([:positive])}")
        },
        project.id
      )
      |> Repo.insert!()

    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    {:ok, role} = Roles.get_role(project_id: project.id, stage: :engineer)

    {:ok, run} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: role.id,
        status: :finished,
        stage_outcome: :done,
        started_at: DateTime.utc_now()
      })

    placeholder =
      "https://linear.app/rail/issue/OPR-1\n\nOpened by Rail as a draft. It is marked ready for review once the change is ready to merge."

    written =
      "## Summary\n\nA call tree.\n\n## Evidence\n\n**Before:** a\n\n**After:** b\n\n## Merge Danger\n\n**Door:** two-way"

    %{
      issue: issue,
      task: task,
      run: run,
      placeholder: placeholder,
      written: written,
      pr_file: Path.join([task.scratch_path, "pr", "OPR-1.md"])
    }
  end

  test "opens the draft with Rail's placeholder, then has an agent with no role describe it", %{
    task: task,
    placeholder: placeholder,
    written: written,
    pr_file: pr_file
  } do
    test = self()

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls"} ->
          send(test, {:searched, conn.query_string})
          Req.Test.json(conn, [])

        {"POST", "/repos/example/test-seed/pulls"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert %{"title" => "OPR-1 Invoice filters", "head" => "opr-1", "base" => "main", "draft" => true} =
                   Jason.decode!(body)

          send(test, {:opened, Jason.decode!(body)["body"]})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "number" => 12,
            "html_url" => "https://github.com/example/test-seed/pull/12",
            "draft" => true
          })

        {"GET", "/repos/example/test-seed/pulls/12"} ->
          Req.Test.json(conn, %{"number" => 12, "draft" => true, "body" => placeholder})

        {"PATCH", "/repos/example/test-seed/pulls/12"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test, {:described, Jason.decode!(body)["body"]})
          Req.Test.json(conn, %{"number" => 12})
      end
    end)

    expect(Tools, :run_agent, fn %{name: :claude}, argv, opts ->
      assert ["-p", _prompt, "--model", "claude-opus-5-5" | _rest] = argv
      refute "--append-system-prompt" in argv
      assert opts[:cd] == "/tmp/repos/test-seed/.worktrees/opr-1"
      File.write!(pr_file, written)
      {:ok, ""}
    end)

    assert :ok = perform_job(OpenPullRequest, %{task_id: task.id})

    assert_received {:searched, query}
    assert %{"state" => "open", "head" => "example:opr-1"} = URI.decode_query(query)
    assert_received {:opened, ^placeholder}
    assert_received {:described, description}
    assert description == "https://linear.app/rail/issue/OPR-1\n\n" <> written

    assert %Task{pr_number: 12, pr_url: "https://github.com/example/test-seed/pull/12", pr_is_draft: true} =
             Repo.reload!(task)
  end

  test "opening the pull request tells the task page, so the button shows without a reload", %{
    task: %Task{id: task_id} = task,
    run: %{id: run_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "run:#{run_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls"} ->
          Req.Test.json(conn, [%{"number" => 9, "html_url" => "https://github.com/x/9", "draft" => true}])

        {"GET", "/repos/example/test-seed/pulls/9"} ->
          Req.Test.json(conn, %{"number" => 9, "body" => "Ada's own description."})
      end
    end)

    assert :ok = perform_job(OpenPullRequest, %{task_id: task.id})
    assert_received {:run_changed, ^run_id}
    assert_received {:pipeline_changed, ^task_id}
  end

  # Rail adopts an open pull request a person opened, and its body was never Rail's.
  test "an adopted pull request keeps its description and no agent runs", %{task: task} do
    test = self()

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        {"GET", "/repos/example/test-seed/pulls"} ->
          Req.Test.json(conn, [%{"number" => 9, "html_url" => "https://github.com/x/9", "draft" => false}])

        {"GET", "/repos/example/test-seed/pulls/9"} ->
          Req.Test.json(conn, %{"number" => 9, "body" => "Ada's own description."})

        {method, path} ->
          send(test, {:unexpected, method, path})
          Req.Test.json(conn, %{})
      end
    end)

    reject(&Tools.run_agent/3)

    assert :ok = perform_job(OpenPullRequest, %{task_id: task.id})
    refute_received {:unexpected, _method, _path}
    assert %Task{pr_number: 9, pr_is_draft: false} = Repo.reload!(task)
  end

  test "a description that fails is retried, and only the last attempt says so in the engineer's log", %{
    task: task,
    run: %{id: run_id},
    placeholder: placeholder
  } do
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 12, pr_url: "https://github.com/x/12", pr_is_draft: true})

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/" <> _id} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"GET", "/repos/example/test-seed/pulls/12"} -> Req.Test.json(conn, %{"number" => 12, "body" => placeholder})
      end
    end)

    stub(Tools, :run_agent, fn _backend, _argv, _opts -> {:error, {:exit, 1}} end)

    assert {:error, {:exit, 1}} = perform_job(OpenPullRequest, %{task_id: task.id})
    assert [] = Repo.all(RunEvent)

    assert {:error, {:exit, 1}} = perform_job(OpenPullRequest, %{task_id: task.id}, attempt: 3)

    assert [%RunEvent{run_id: ^run_id, line: "[rail] Could not write the pull request description: {:exit, 1}"}] =
             Repo.all(RunEvent)

    assert %Task{pr_number: 12, pr_is_draft: true} = Repo.reload!(task)
  end

  test "a pull request that cannot be opened says so in the engineer's log on the last attempt", %{
    task: task,
    run: %{id: run_id}
  } do
    Req.Test.stub(Client, &(&1 |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})))
    reject(&Tools.run_agent/3)

    assert {:error, {:github_api_error, 404, _body}} = perform_job(OpenPullRequest, %{task_id: task.id})
    assert [] = Repo.all(RunEvent)

    assert {:error, _reason} = perform_job(OpenPullRequest, %{task_id: task.id}, attempt: 3)

    assert [%RunEvent{run_id: ^run_id, line: "[rail] Could not open the pull request: " <> _reason}] =
             Repo.all(RunEvent)

    assert %Task{pr_number: nil} = Repo.reload!(task)
  end

  test "the pull request is opened as the ticket's owner", %{task: task, issue: issue} do
    {:ok, owner} =
      %User{}
      |> User.changeset(%{
        github_id: "gh_opr",
        login: "ada",
        name: "Ada",
        email: "ada@example.com",
        github_token: "gho_ada"
      })
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: owner.id})

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")} do
        {"POST", "/app/installations/" <> _id, _auth} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", "/repos/example/test-seed/pulls", ["Bearer ghs_app"]} ->
          Req.Test.json(conn, [])

        {"POST", "/repos/example/test-seed/pulls", ["Bearer gho_ada"]} ->
          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{"number" => 21, "html_url" => "https://github.com/example/test-seed/pull/21"})

        {"GET", "/repos/example/test-seed/pulls/21", _auth} ->
          Req.Test.json(conn, %{"number" => 21, "body" => "Edited already."})
      end
    end)

    assert :ok = perform_job(OpenPullRequest, %{task_id: task.id})
    assert %Task{pr_number: 21} = Repo.reload!(task)
  end

  test "an owner GitHub turns away has the pull request opened as the Rail app", %{task: task, issue: issue} do
    {:ok, owner} =
      %User{}
      |> User.changeset(%{github_id: "gh_opr2", login: "bo", name: "Bo", email: "bo@example.com", github_token: "gho_bo"})
      |> Repo.insert()

    {:ok, _assigned} = Issues.update_issue(issue, %{owner_user_id: owner.id})

    Req.Test.stub(Client, fn conn ->
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

        {"GET", "/repos/example/test-seed/pulls/22", _auth} ->
          Req.Test.json(conn, %{"number" => 22, "body" => "Edited already."})
      end
    end)

    assert :ok = perform_job(OpenPullRequest, %{task_id: task.id})
    assert %Task{pr_number: 22} = Repo.reload!(task)
  end

  test "a task that is gone or cleaned up has nothing to open", %{task: task} do
    assert :ok = perform_job(OpenPullRequest, %{task_id: "tsk_gone"})

    {:ok, task} = Pipeline.update_task(task, %{cleaned_up_at: DateTime.utc_now()})
    assert :ok = perform_job(OpenPullRequest, %{task_id: task.id})
  end

  test "outlasts the agent it waits on" do
    assert OpenPullRequest.timeout(%Oban.Job{}) == to_timeout(minute: 20)
  end
end
