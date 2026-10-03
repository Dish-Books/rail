defmodule Rail.Learnings.Workers.CollectPullRequestTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.GitHub.Client
  alias Rail.Learnings.Schemas.Observation
  alias Rail.Learnings.Schemas.ProcessedPullRequest
  alias Rail.Learnings.Workers.CollectPullRequest
  alias Rail.Pipeline
  alias Rail.Users

  setup %{project: project} do
    {:ok, user} =
      Users.register_oauth_user(%{github_id: "cpr-1", login: "dana-cpr", name: "Dana", email: "dana@cpr.example"})

    task = learnings_task(project, "CPR-1")
    {:ok, task} = Pipeline.update_task(task, %{pr_number: 118})
    %{task: task, user_id: user.id}
  end

  test "human review comments and review bodies become observations on the PR's task, and the PR is read", %{
    project: project,
    task: %{id: task_id},
    user_id: user_id
  } do
    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-seed/pulls/118/comments" ->
          Req.Test.json(conn, [
            %{
              "id" => 1,
              "body" => "attrs are the docs for these",
              "user" => %{"login" => "dana-cpr", "type" => "User"},
              "path" => "lib/a.ex",
              "diff_hunk" => "@@ -1 +1 @@",
              "html_url" => "https://github.com/x/pull/118#r1"
            },
            %{"id" => 2, "body" => "Coverage dropped", "user" => %{"login" => "codecov", "type" => "Bot"}}
          ])

        "/repos/example/test-seed/pulls/118/reviews" ->
          Req.Test.json(conn, [
            %{"id" => 3, "body" => "Factory, not Repo", "user" => %{"login" => "someone", "type" => "User"}},
            %{"id" => 4, "body" => "", "user" => %{"login" => "someone", "type" => "User"}}
          ])
      end
    end)

    assert :ok = perform_job(CollectPullRequest, %{project_id: project.id, number: 118})

    assert [
             %Observation{
               source_kind: :pr_review,
               source_id: "3",
               actor_name: "someone",
               actor_id: nil,
               task_id: ^task_id
             },
             %Observation{
               source_kind: :pr_review_comment,
               source_id: "1",
               actor_id: ^user_id,
               excerpt: "lib/a.ex\n@@ -1 +1 @@",
               source_url: "https://github.com/x/pull/118#r1"
             }
           ] = Repo.all(from o in Observation, where: o.project_id == ^project.id, order_by: o.source_kind)

    assert Repo.get_by(ProcessedPullRequest, project_id: project.id, number: 118)
  end

  test "a PR already read makes no request, and a project that is gone has nothing to read", %{project: project} do
    Repo.insert!(%ProcessedPullRequest{project_id: project.id, number: 118})
    Req.Test.stub(Client, fn _conn -> flunk("a read PR was fetched again") end)

    assert :ok = perform_job(CollectPullRequest, %{project_id: project.id, number: 118})
    assert :ok = perform_job(CollectPullRequest, %{project_id: "prj_gone", number: 1})
  end

  test "a failed fetch records neither observations nor the PR", %{project: project} do
    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest -> Req.Test.json(conn, %{"token" => "ghs_token"})
        _comments -> Req.Test.json(Plug.Conn.put_status(conn, 502), %{"message" => "Bad gateway"})
      end
    end)

    assert {:error, {:github_api_error, 502, _body}} =
             perform_job(CollectPullRequest, %{project_id: project.id, number: 118})

    refute Repo.get_by(ProcessedPullRequest, project_id: project.id, number: 118)
    assert [] = Repo.all(from o in Observation, where: o.project_id == ^project.id)
  end

  test "a PR from no Rail task, or an abandoned one, is still read", %{project: project, task: task} do
    {:ok, _issue} = Rail.Issues.update_issue(task.issue, %{state: :canceled})

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-seed/pulls/" <> rest ->
          if rest =~ "reviews",
            do:
              Req.Test.json(conn, [
                %{"id" => String.length(rest), "body" => "Hm", "user" => %{"login" => "x", "type" => "User"}}
              ]),
            else: Req.Test.json(conn, [])
      end
    end)

    assert :ok = perform_job(CollectPullRequest, %{project_id: project.id, number: 118})
    assert :ok = perform_job(CollectPullRequest, %{project_id: project.id, number: 9})

    assert [%Observation{abandoned: false, task_id: nil}, %Observation{abandoned: true}] =
             Repo.all(from o in Observation, where: o.project_id == ^project.id, order_by: [asc: o.abandoned])
  end
end
