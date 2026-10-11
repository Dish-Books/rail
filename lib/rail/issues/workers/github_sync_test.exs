defmodule Rail.Issues.Workers.GithubSyncTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.GithubSync
  alias Rail.Learnings.Workers.IssueFinished
  alias Rail.Users

  setup {Req.Test, :verify_on_exit!}

  test "a full pull starts with the open issues, keeping Rail's branch name and leaving pull requests out", %{
    github_project: %{id: project_id} = project
  } do
    {:ok, %{id: assignee_id}} =
      Users.register_oauth_user(%{github_id: "5150", login: "assignee", email: "as@example.com"})

    %Issue{id: existing_id} =
      existing = github_issue(project, %{number: 1, title: "Old title", branch_name: "tgh-1-old-title"})

    Req.Test.expect(Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/issues" ->
          assert %{"state" => "open", "page" => "1", "sort" => "updated", "direction" => "asc"} = conn.query_params
          refute Map.has_key?(conn.query_params, "since")

          Req.Test.json(conn, [
            github_issue_json(%{"node_id" => existing.external_id, "number" => 1, "title" => "New title"}),
            github_issue_json(%{
              "number" => 2,
              "title" => "Filed on GitHub",
              "labels" => [%{"name" => "rail:todo"}, %{"name" => "rail:low"}],
              "assignees" => [%{"id" => 777}, %{"id" => 5150}]
            }),
            github_issue_json(%{"number" => 3, "pull_request" => %{"url" => "https://api.github.com/pulls/3"}})
          ])
      end
    end)

    assert :ok = perform_job(GithubSync, %{project_id: project_id})

    assert %Issue{id: ^existing_id, title: "New title", branch_name: "tgh-1-old-title", state: :backlog} =
             Repo.reload!(existing)

    assert %Issue{
             identifier: "tgh#2",
             tracker: :github,
             state: :todo,
             priority: :low,
             owner_user_id: ^assignee_id,
             branch_name: "tgh-2-filed-on-github"
           } = Repo.get_by!(Issue, project_id: project_id, number: 2)

    refute Repo.get_by(Issue, project_id: project_id, number: 3)
    assert_enqueued(worker: GithubSync, args: %{project_id: project_id, pass: "closed", page: 1})
  end

  test "the closed pass keeps only what closed in the last 30 days, and hands finishes to Learnings", %{
    github_project: %{id: project_id} = project
  } do
    active = github_issue(project, %{number: 4, state: :in_review})
    recently = DateTime.utc_now() |> DateTime.shift(day: -1) |> DateTime.to_iso8601()

    Req.Test.expect(Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/issues" ->
          assert %{"state" => "closed", "since" => _thirty_days_ago} = conn.query_params

          Req.Test.json(conn, [
            github_issue_json(%{
              "node_id" => active.external_id,
              "number" => 4,
              "state" => "closed",
              "state_reason" => "completed",
              "closed_at" => recently
            }),
            github_issue_json(%{
              "number" => 5,
              "state" => "closed",
              "state_reason" => "not_planned",
              "closed_at" => recently
            }),
            github_issue_json(%{
              "number" => 6,
              "state" => "closed",
              "state_reason" => "duplicate",
              "closed_at" => recently
            }),
            github_issue_json(%{"number" => 7, "state" => "closed", "closed_at" => "2020-01-01T00:00:00Z"}),
            github_issue_json(%{"number" => 8, "state" => "closed", "closed_at" => nil})
          ])
      end
    end)

    assert :ok = perform_job(GithubSync, %{project_id: project_id, pass: "closed", page: 1})

    assert %Issue{state: :done, state_name: "Done", completed_at: %DateTime{}} = Repo.reload!(active)
    assert %Issue{state: :canceled} = Repo.get_by!(Issue, project_id: project_id, number: 5)
    assert %Issue{state: :duplicate} = Repo.get_by!(Issue, project_id: project_id, number: 6)
    refute Repo.get_by(Issue, project_id: project_id, number: 7)
    refute Repo.get_by(Issue, project_id: project_id, number: 8)

    assert [_once] = all_enqueued(worker: IssueFinished)
    assert_enqueued(worker: IssueFinished, args: %{issue_id: active.id})
    assert_enqueued(worker: GithubSync, args: %{project_id: project_id, pass: "comments", page: 1})
  end

  test "Rail's owner stays unless GitHub names a different Rail user", %{github_project: %{id: project_id} = project} do
    [%{id: kept_id}, %{id: other_id}] =
      Enum.map(["7001", "7002"], fn github_id ->
        {:ok, user} =
          Users.register_oauth_user(%{github_id: github_id, login: "u#{github_id}", email: "u#{github_id}@example.com"})

        user
      end)

    kept = github_issue(project, %{number: 31, owner_user_id: kept_id})
    moved = github_issue(project, %{number: 32, owner_user_id: kept_id})

    Req.Test.expect(Client, 2, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/issues" ->
          Req.Test.json(conn, [
            github_issue_json(%{"node_id" => kept.external_id, "number" => 31, "assignees" => [%{"id" => 404}]}),
            github_issue_json(%{"node_id" => moved.external_id, "number" => 32, "assignees" => [%{"id" => 7002}]})
          ])
      end
    end)

    assert :ok = perform_job(GithubSync, %{project_id: project_id, pass: "open", page: 1})

    assert %Issue{owner_user_id: ^kept_id} = Repo.reload!(kept)
    assert %Issue{owner_user_id: ^other_id} = Repo.reload!(moved)
  end

  test "a pass with nothing in it moves on to the next", %{github_project: %{id: project_id}} do
    Req.Test.expect(Client, 2, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/example/test-gh/issues" -> Req.Test.json(conn, [])
      end
    end)

    assert :ok = perform_job(GithubSync, %{project_id: project_id})
    assert_enqueued(worker: GithubSync, args: %{project_id: project_id, pass: "closed", page: 1})
  end

  test "a full page queues the next one, asking from the same point", %{github_project: %{id: project_id}} do
    Req.Test.expect(Client, 2, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/issues" ->
          Req.Test.json(conn, Enum.map(1..100, &github_issue_json(%{"number" => 1000 + &1})))
      end
    end)

    assert :ok = perform_job(GithubSync, %{project_id: project_id, pass: "open", page: 1})
    assert_enqueued(worker: GithubSync, args: %{project_id: project_id, pass: "open", page: 2})
  end

  test "the comments pass files each comment under its issue and says the sync is done", %{
    github_project: %{id: project_id} = project
  } do
    {:ok, %{id: author_id}} = Users.register_oauth_user(%{github_id: "8080", login: "commenter", email: "cm@example.com"})
    %Issue{id: issue_id} = github_issue(project, %{number: 21})
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    Req.Test.expect(Client, 2, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/issues/comments" ->
          Req.Test.json(conn, [
            github_comment_json(%{
              "body" => "Looks right",
              "user" => %{"id" => 8080, "login" => "commenter"},
              "issue_url" => "https://api.github.com/repos/example/test-gh/issues/21"
            }),
            github_comment_json(%{"issue_url" => "https://api.github.com/repos/example/test-gh/issues/999"}),
            github_comment_json(%{"issue_url" => nil}),
            github_comment_json(%{"issue_url" => "https://api.github.com/repos/example/test-gh/issues/x"})
          ])
      end
    end)

    assert :ok = perform_job(GithubSync, %{project_id: project_id, pass: "comments", page: 1})

    assert [%Comment{body: "Looks right", author_user_id: ^author_id, author_name: "commenter"}] =
             Repo.all(from c in Comment, where: c.issue_id == ^issue_id)

    assert_received {:issue_comments_changed, ^issue_id}
    assert_received {:issues_synced, ^project_id}
  end

  test "a full page of comments queues the next one", %{github_project: %{id: project_id}} do
    Req.Test.expect(Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-gh/issues/comments" ->
          assert %{"page" => "1"} = conn.query_params
          refute Map.has_key?(conn.query_params, "since")
          Req.Test.json(conn, Enum.map(1..100, fn _comment -> github_comment_json() end))
      end
    end)

    assert :ok = perform_job(GithubSync, %{project_id: project_id, pass: "comments"})
    assert_enqueued(worker: GithubSync, args: %{project_id: project_id, pass: "comments", page: 2})
  end

  test "a Linear project or one that is gone has nothing to pull, and a refused token retries", %{
    project: project,
    github_project: github_project
  } do
    assert :ok = perform_job(GithubSync, %{project_id: project.id})
    assert :ok = perform_job(GithubSync, %{project_id: "prj_gone"})

    Req.Test.expect(Client, fn conn -> conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{}) end)
    assert {:error, _reason} = perform_job(GithubSync, %{project_id: github_project.id})
  end

  test "the Sync button pulls a GitHub project in full", %{github_project: %{id: project_id} = project} do
    assert {:ok, _job} = Issues.sync_issues(project)
    assert_enqueued(worker: GithubSync, args: %{project_id: project_id})
  end
end
