defmodule Rail.Pipeline.Actions.HandleCoderabbitCheckTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users

  setup %{project: project} do
    scratch = Path.join(System.tmp_dir!(), "coderabbit_check_#{System.unique_integer([:positive])}")
    worktree = Path.join(scratch, "worktree")
    Enum.each([worktree, worktree <> ".git"], &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(scratch) end)
    head = String.duplicate("d", 40)
    stub(Git, :branch_fingerprint, fn _path -> %{head_sha: head, dirty_digest: "clean"} end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Issue", description: "CodeRabbit check"})
    {:ok, task} = Pipeline.create_task(issue, :review)

    {:ok, task} =
      Pipeline.update_task(task, %{pr_number: 152, worktree_path: worktree, scratch_path: Path.join(scratch, "scratch")})

    {:ok, _round} = Pipeline.create_round(task)

    {:ok, dev} =
      Users.register_oauth_user(%{github_id: "gh_crc_dev", login: "dev-crc", email: "dev-crc@example.com"})

    {:ok, dev} =
      Users.update_user(system_scope(), dev, %{
        project_ids: [project.id],
        github_token: "gho_dev_crc",
        github_token_expires_at: ~U[2100-01-01 00:00:00.000000Z]
      })

    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})))
    scope = Scope.for_user(dev)
    {:ok, review} = Pipeline.request_coderabbit_review(scope, task)

    {:ok, lead_role} = Roles.get_role(project_id: project.id, stage: :review_lead)

    {:ok, lead} =
      Pipeline.create_run(%{
        task_id: task.id,
        role_id: lead_role.id,
        status: :running,
        conversation_id: "sess_coderabbit_lead",
        started_at: DateTime.utc_now()
      })

    check = fn action, attrs ->
      %{
        "action" => action,
        "check_run" =>
          Map.merge(
            %{
              "name" => "CodeRabbit",
              "app" => %{"slug" => "coderabbitai"},
              "head_sha" => head,
              "status" => if(action == "completed", do: "completed", else: "in_progress"),
              "pull_requests" => [%{"number" => 152}]
            },
            attrs
          )
      }
    end

    later = DateTime.utc_now() |> DateTime.shift(second: 5) |> DateTime.to_iso8601()

    %{task: task, scope: scope, review: review, lead: lead, check: check, later: later}
  end

  test "CodeRabbit starting marks the review under way", %{project: project, review: %{id: id}, check: check} do
    assert {:ok, %CoderabbitReview{id: ^id, status: :reviewing}} =
             Pipeline.handle_coderabbit_check(project, check.("created", %{}))

    # A second start changes nothing.
    assert {:ok, %CoderabbitReview{status: :reviewing}} =
             Pipeline.handle_coderabbit_check(project, check.("created", %{}))
  end

  test "a finished review's comments since it was asked become CodeRabbit's report, sent to the lead", %{
    project: project,
    task: task,
    review: %{id: id},
    lead: lead,
    check: check,
    later: later
  } do
    long = String.duplicate("x", 4_100)

    Req.Test.stub(Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/app/installations/1/access_tokens"} ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        {"GET", "/repos/example/test-seed/pulls/152/reviews"} ->
          Req.Test.json(conn, [
            %{"id" => 1, "user" => %{"login" => "coderabbitai[bot]"}, "submitted_at" => "2020-01-01T00:00:00Z"},
            %{"id" => 2, "user" => %{"login" => "coderabbitai[bot]"}, "submitted_at" => later, "body" => "Nitpicks: 1"},
            %{"id" => 3, "user" => %{"login" => "someone"}, "submitted_at" => later, "body" => "LGTM"},
            %{"id" => 4, "user" => %{"login" => "coderabbitai[bot]"}, "submitted_at" => nil},
            %{"id" => 5, "user" => %{"login" => "coderabbitai[bot]"}, "submitted_at" => "not a date"}
          ])

        {"GET", "/repos/example/test-seed/pulls/152/comments"} ->
          Req.Test.json(conn, [
            %{"pull_request_review_id" => 1, "path" => "lib/old.ex", "line" => 1, "body" => "Old"},
            %{
              "pull_request_review_id" => 2,
              "path" => "lib/auth.ex",
              "start_line" => 10,
              "line" => 14,
              "body" => "Potential issue: the token is compared with ==."
            },
            %{"pull_request_review_id" => 2, "path" => "lib/long.ex", "original_line" => 3, "body" => long},
            %{"pull_request_review_id" => 3, "path" => "lib/other.ex", "line" => 2, "body" => "Not CodeRabbit"}
          ])
      end
    end)

    assert {:ok, %CoderabbitReview{id: ^id, status: :done, comment_count: 2, finished_at: %DateTime{}}} =
             Pipeline.handle_coderabbit_check(project, check.("completed", %{"conclusion" => "success"}))

    report = [task.scratch_path, "reports", "coderabbit.md"] |> Path.join() |> File.read!()
    assert report =~ "### lib/auth.ex:10-14"
    assert report =~ "### lib/long.ex:3"
    assert report =~ "Nitpicks: 1"
    assert report =~ "[cut]"
    refute report =~ "lib/old.ex"
    refute report =~ "Not CodeRabbit"
    assert Keyword.has_key?(Pipeline.read_reports(task), :coderabbit)

    assert %Run{pending_chat: note} = Repo.reload!(lead)
    assert note =~ "raised_by: coderabbit"
    assert note =~ "the token is compared with =="
  end

  test "a review that submitted nothing since it was asked tells the lead there is nothing to add", %{
    project: project,
    task: task,
    lead: lead,
    check: check
  } do
    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" -> Req.Test.json(conn, %{"token" => "ghs_app"})
        _reviews_or_comments -> Req.Test.json(conn, [])
      end
    end)

    assert {:ok, %CoderabbitReview{status: :done, comment_count: 0}} =
             Pipeline.handle_coderabbit_check(project, check.("completed", %{"conclusion" => "neutral"}))

    refute File.exists?(Path.join([task.scratch_path, "reports", "coderabbit.md"]))
    assert %Run{pending_chat: note} = Repo.reload!(lead)
    assert note =~ "ended with nothing to add (Done)"
  end

  test "a rate limit, a skip and a failure end the review with nothing to report", %{
    project: project,
    task: task,
    scope: scope,
    check: check
  } do
    asked = fn ->
      Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(201) |> Req.Test.json(%{"id" => 1})))
      Pipeline.request_coderabbit_review(scope, task)
    end

    limited = check.("completed", %{"conclusion" => "success", "output" => %{"title" => "Review rate limited"}})
    assert {:ok, %CoderabbitReview{status: :rate_limited}} = Pipeline.handle_coderabbit_check(project, limited)

    {:ok, _again} = asked.()
    skipped = check.("completed", %{"conclusion" => "skipped"})
    assert {:ok, %CoderabbitReview{status: :skipped}} = Pipeline.handle_coderabbit_check(project, skipped)

    {:ok, _again} = asked.()
    failed = check.("completed", %{"conclusion" => "failure"})
    assert {:ok, %CoderabbitReview{status: :failed}} = Pipeline.handle_coderabbit_check(project, failed)

    {:ok, _again} = asked.()
    Req.Test.expect(Client, &(&1 |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "down"})))
    unread = check.("completed", %{"conclusion" => "success"})
    assert {:ok, %CoderabbitReview{status: :failed}} = Pipeline.handle_coderabbit_check(project, unread)
  end

  test "while QA and the code reviewer still check the round, the lead reads the report when it starts", %{
    project: project,
    task: task,
    lead: lead,
    check: check,
    later: later
  } do
    {:ok, qa} = Roles.get_role(project_id: project.id, stage: :qa)

    {:ok, _qa_run} =
      Pipeline.create_run(%{task_id: task.id, role_id: qa.id, status: :running, started_at: DateTime.utc_now()})

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_app"})

        "/repos/example/test-seed/pulls/152/reviews" ->
          Req.Test.json(conn, [%{"id" => 9, "user" => %{"login" => "coderabbitai[bot]"}, "submitted_at" => later}])

        _comments ->
          Req.Test.json(conn, [])
      end
    end)

    assert {:ok, %CoderabbitReview{status: :done}} =
             Pipeline.handle_coderabbit_check(project, check.("completed", %{"conclusion" => "success"}))

    assert File.exists?(Path.join([task.scratch_path, "reports", "coderabbit.md"]))
    assert %Run{pending_chat: nil} = Repo.reload!(lead)
  end

  test "a task that left Review keeps the review's record and tells nobody", %{
    project: project,
    task: task,
    lead: lead,
    check: check
  } do
    {:ok, _engineer} = Pipeline.update_task(task, %{stage: :engineer})

    assert {:ok, %CoderabbitReview{status: :failed}} =
             Pipeline.handle_coderabbit_check(project, check.("completed", %{"conclusion" => "cancelled"}))

    assert %Run{pending_chat: nil} = Repo.reload!(lead)
  end

  test "a check matched by its commit when it names no pull request, and by name when it names no app", %{
    project: project,
    check: check
  } do
    started = check.("created", %{"pull_requests" => [], "app" => nil})
    assert {:ok, %CoderabbitReview{status: :reviewing}} = Pipeline.handle_coderabbit_check(project, started)
  end

  test "another app's check, a payload with no check, and a check Rail is not waiting on are ignored", %{
    project: project,
    check: check
  } do
    other = check.("completed", %{"name" => "CI", "app" => %{"slug" => "github-actions"}})
    assert :ignored = Pipeline.handle_coderabbit_check(project, other)
    assert :ignored = Pipeline.handle_coderabbit_check(project, %{"action" => "completed"})

    elsewhere = check.("created", %{"pull_requests" => [%{"number" => 999}], "head_sha" => nil})
    assert :ignored = Pipeline.handle_coderabbit_check(project, elsewhere)
  end
end
