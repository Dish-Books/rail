defmodule Rail.Pipeline.Actions.ApproveTaskTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    Req.Test.stub(Rail.Linear, fn conn ->
      n = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_at_#{n}", "identifier" => "AT-#{n}", "title" => "Approve Task #{n}"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Approve Task"})
    {:ok, task} = Pipeline.create_task(issue, :finalize)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 151, marked_ready_at: DateTime.utc_now()})

    {:ok, priya} = Users.register_oauth_user(%{github_id: "gh_at_priya", login: "priya", email: "priya@example.com"})

    {:ok, priya} =
      Users.update_user(system_scope(), priya, %{
        name: "Priya Raman",
        tech_lead: true,
        project_ids: [project.id],
        github_token: "gho_priya"
      })

    # GitHub as the test sees it: an approval the lead posts is listed from then on.
    {:ok, reviews} = Agent.start_link(fn -> [] end)
    test_pid = self()

    github = fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", "/repos/example/test-seed/pulls/151/reviews"} ->
          assert ["Bearer ghs_app"] = Plug.Conn.get_req_header(conn, "authorization")
          Req.Test.json(conn, Agent.get(reviews, & &1))

        {"POST", "/repos/example/test-seed/pulls/151/reviews"} ->
          assert ["Bearer gho_priya"] = Plug.Conn.get_req_header(conn, "authorization")
          send(test_pid, {:posting, self()})
          review = %{"id" => 80, "user" => %{"login" => "priya"}, "state" => "APPROVED"}
          Agent.update(reviews, &[Map.put(review, "submitted_at", "2026-10-11T14:40:00Z") | &1])
          Req.Test.json(conn, review)
      end
    end

    %{task: task, lead: priya, scope: Scope.for_user(priya), github: github}
  end

  test "a tech lead's approval goes to GitHub as the lead, comes back in the approvals and is heard by every page", %{
    task: %Task{id: task_id} = task,
    lead: %User{id: lead_id},
    scope: scope,
    github: github
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")
    Req.Test.stub(Client, github)

    assert {:ok, [%{login: "priya", user: %User{id: ^lead_id}, approved_at: ~U[2026-10-11 14:40:00Z]}]} =
             Pipeline.approve_task(scope, task)

    assert_received {:posting, _github}
    assert_received {:approvals_changed, ^task_id}
  end

  test "a refusal returns GitHub's message with its errors, and writes and broadcasts nothing", %{
    task: %Task{id: task_id, updated_at: updated_at} = task,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")
    Phoenix.PubSub.subscribe(Rail.PubSub, "pipeline")

    Req.Test.expect(Client, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", _reviews} ->
          Req.Test.json(conn, [])

        {"POST", _reviews} ->
          assert ["Bearer gho_priya"] = Plug.Conn.get_req_header(conn, "authorization")

          conn
          |> Plug.Conn.put_status(422)
          |> Req.Test.json(%{
            "message" => "Unprocessable Entity",
            "errors" => ["Can not approve your own pull request", %{"message" => "Review cannot be submitted"}, 7]
          })
      end
    end)

    assert {:error,
            {:approve_refused, "Unprocessable Entity: Can not approve your own pull request: Review cannot be submitted"}} =
             Pipeline.approve_task(scope, task)

    assert %Task{updated_at: ^updated_at, merge_error: nil} = Repo.reload!(task)
    refute_received {:approvals_changed, ^task_id}
    refute_received {:pipeline_changed, ^task_id}
  end

  test "a refusal GitHub gives no message for still says why", %{
    task: task,
    scope: scope
  } do
    Req.Test.expect(Client, 3, fn conn ->
      case conn.method do
        "POST" when conn.request_path == "/app/installations/1/access_tokens" -> Req.Test.json(conn, %{"token" => "t"})
        "GET" -> Req.Test.json(conn, [])
        "POST" -> conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{})
      end
    end)

    assert {:error, {:approve_refused, "GitHub answered 502."}} = Pipeline.approve_task(scope, task)
  end

  # GitHub may have recorded an approval whose answer never came back, so it is not called a refusal.
  test "an approval that never heard back from GitHub returns the connection's error, not a refusal", %{
    task: %Task{id: task_id} = task,
    scope: scope
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")

    Req.Test.expect(Client, 3, fn conn ->
      case conn.method do
        "POST" when conn.request_path == "/app/installations/1/access_tokens" -> Req.Test.json(conn, %{"token" => "t"})
        "GET" -> Req.Test.json(conn, [])
        "POST" -> Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:error, %Req.TransportError{reason: :timeout}} = Pipeline.approve_task(scope, task)
    refute_received {:approvals_changed, ^task_id}
  end

  test "an approval GitHub took but that cannot be read back is still heard by every page", %{
    task: %Task{id: task_id} = task,
    scope: scope,
    github: github
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task_id}")
    {:ok, reads} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Client, fn conn ->
      read = if conn.method == "GET", do: Agent.get_and_update(reads, &{&1 + 1, &1 + 1})

      if read == 2,
        do: conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{}),
        else: github.(conn)
    end)

    assert {:ok, :unread} = Pipeline.approve_task(scope, task)
    assert_received {:posting, _github}
    assert_received {:approvals_changed, ^task_id}
  end

  test "approvals GitHub cannot read come back as the read's error, and nothing is posted", %{
    task: task,
    scope: scope
  } do
    Req.Test.expect(Client, 2, fn conn ->
      case conn.method do
        "POST" -> Req.Test.json(conn, %{"token" => "ghs_app"})
        "GET" -> conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{})
      end
    end)

    assert {:error, {:github_api_error, 502, %{}}} = Pipeline.approve_task(scope, task)
  end

  # The default adapter fails any call the test does not expect, the app's token included.
  test "a lead with no GitHub token is told so and nothing goes to GitHub", %{task: task, lead: lead} do
    {:ok, tokenless} = Users.update_user(system_scope(), lead, %{github_token: nil})

    assert {:error, :no_github_token} = Pipeline.approve_task(Scope.for_user(tokenless), task)
  end

  test "a teammate without the setting is refused, admins included", %{project: project, task: task} do
    {:ok, admin} = Users.register_oauth_user(%{github_id: "gh_at_admin", login: "admin", email: "a@example.com"})
    {:ok, admin} = Users.update_user(system_scope(), admin, %{admin: true, github_token: "gho_admin"})
    {:ok, dan} = Users.register_oauth_user(%{github_id: "gh_at_dan", login: "dano", email: "d@example.com"})
    {:ok, dan} = Users.update_user(system_scope(), dan, %{project_ids: [project.id], github_token: "gho_dan"})

    assert {:error, :not_authorized} = Pipeline.approve_task(Scope.for_user(admin), task)
    assert {:error, :not_authorized} = Pipeline.approve_task(Scope.for_user(dan), task)
  end

  test "a tech lead without access to the project is refused", %{task: task, lead: lead} do
    assert {:error, :not_found} = Pipeline.approve_task(Scope.for_user(%{lead | project_ids: []}), task)
  end

  test "a task not ready, already merged, at another stage or with no pull request is refused", %{
    task: task,
    scope: scope
  } do
    {:ok, unmarked} = Pipeline.update_task(task, %{marked_ready_at: nil})
    assert {:error, :not_ready} = Pipeline.approve_task(scope, unmarked)

    {:ok, merged} =
      Pipeline.update_task(unmarked, %{stage: :merged, marked_ready_at: DateTime.utc_now(), merged_at: DateTime.utc_now()})

    assert {:error, :merged} = Pipeline.approve_task(scope, merged)

    {:ok, reviewing} = Pipeline.update_task(merged, %{stage: :review, merged_at: nil})
    assert {:error, {:invalid_stage, :review}} = Pipeline.approve_task(scope, reviewing)

    {:ok, no_pr} = Pipeline.update_task(reviewing, %{stage: :finalize, pr_number: nil})
    assert {:error, :no_pull_request} = Pipeline.approve_task(scope, no_pr)
  end

  test "a lead whose approval is current gets it back without posting another", %{
    task: task,
    scope: scope,
    github: github
  } do
    Req.Test.stub(Client, github)
    assert {:ok, [%{login: "priya"}]} = Pipeline.approve_task(scope, task)
    assert_received {:posting, _github}

    assert {:ok, [%{login: "priya"}]} = Pipeline.approve_task(scope, task)
    refute_received {:posting, _github}
  end

  # The first click's review is held at GitHub, so a second click that did not wait for it would post its own.
  test "two approvals at once post one review", %{task: task, scope: scope, github: github} do
    test_pid = self()

    Req.Test.stub(Client, fn conn ->
      if {conn.method, conn.request_path} == {"POST", "/repos/example/test-seed/pulls/151/reviews"} do
        send(test_pid, {:held, self()})
        assert_receive :answer, 2_000
      end

      github.(conn)
    end)

    first = Elixir.Task.async(fn -> Pipeline.approve_task(scope, task) end)
    second = Elixir.Task.async(fn -> Pipeline.approve_task(scope, task) end)

    assert_receive {:held, held}, 2_000
    refute_receive {:held, _other}, 200
    send(held, :answer)

    assert {:ok, [%{login: "priya"}]} = Elixir.Task.await(first)
    assert {:ok, [%{login: "priya"}]} = Elixir.Task.await(second)
    assert_received {:posting, _github}
    refute_received {:posting, _github}
  end
end
