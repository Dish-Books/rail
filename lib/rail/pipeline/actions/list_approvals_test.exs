defmodule Rail.Pipeline.Actions.ListApprovalsTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    Req.Test.stub(Rail.Linear, fn conn ->
      n = System.unique_integer([:positive])

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_la_#{n}", "identifier" => "LA-#{n}", "title" => "List Approvals #{n}"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "List Approvals"})
    {:ok, task} = Pipeline.create_task(issue, :finalize)
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 151, marked_ready_at: DateTime.utc_now()})

    {:ok, %User{id: priya_id}} =
      Users.register_oauth_user(%{github_id: "gh_la_priya", login: "priya-la", email: "priya-la@example.com"})

    %{task: task, priya_id: priya_id}
  end

  test "each reviewer's latest review that is not a comment decides their approval, named by their Rail account", %{
    task: task,
    priya_id: priya_id
  } do
    review = fn login, state, at -> %{"user" => %{"login" => login}, "state" => state, "submitted_at" => at} end

    Req.Test.expect(Client, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", "/repos/example/test-seed/pulls/151/reviews"} ->
          assert ["Bearer ghs_app"] = Plug.Conn.get_req_header(conn, "authorization")

          Req.Test.json(conn, [
            review.("priya-la", "APPROVED", "2026-10-10T16:02:00Z"),
            review.("priya-la", "COMMENTED", "2026-10-10T16:30:00Z"),
            review.("dana", "APPROVED", "2026-10-10T15:00:00Z"),
            review.("dana", "CHANGES_REQUESTED", "2026-10-10T17:00:00Z"),
            review.("omar", "APPROVED", "2026-10-10T15:10:00Z"),
            review.("omar", "DISMISSED", "2026-10-10T15:10:00Z"),
            review.("jkowalski-dev", "CHANGES_REQUESTED", "2026-10-09T09:00:00Z"),
            review.("jkowalski-dev", "APPROVED", "2026-10-10T16:02:00Z"),
            review.("bea", "APPROVED", "2026-10-10T14:00:00Z"),
            %{"user" => nil, "state" => "APPROVED", "submitted_at" => "2026-10-10T14:00:00Z"},
            %{"user" => %{"login" => "pending"}, "state" => "PENDING", "submitted_at" => nil}
          ])
      end
    end)

    assert {:ok,
            [
              %{login: "bea", user: nil, approved_at: ~U[2026-10-10 14:00:00Z]},
              %{login: "jkowalski-dev", user: nil, approved_at: ~U[2026-10-10 16:02:00Z]},
              %{login: "priya-la", user: %User{id: ^priya_id}, approved_at: ~U[2026-10-10 16:02:00Z]}
            ]} = Pipeline.list_approvals(task)
  end

  test "a task with no pull request has none, and GitHub asks for nothing", %{task: task} do
    {:ok, no_pr} = Pipeline.update_task(task, %{pr_number: nil})

    assert {:ok, []} = Pipeline.list_approvals(no_pr)
  end

  test "a GitHub error comes back as an error", %{task: task} do
    Req.Test.expect(Client, 2, fn conn ->
      case conn.method do
        "POST" -> Req.Test.json(conn, %{"token" => "ghs_app"})
        "GET" -> conn |> Plug.Conn.put_status(502) |> Req.Test.json(%{"message" => "Bad Gateway"})
      end
    end)

    assert {:error, {:github_api_error, 502, %{"message" => "Bad Gateway"}}} = Pipeline.list_approvals(task)
  end
end
