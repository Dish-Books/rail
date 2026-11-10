defmodule RailWeb.GithubWebhookControllerTest do
  use RailWeb.ConnCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Repo

  setup %{conn: conn} do
    sign = fn conn, body, event ->
      signature = :hmac |> :crypto.mac(:sha256, "github_webhook_secret", body) |> Base.encode16(case: :lower)

      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-github-event", event)
      |> put_req_header("x-hub-signature-256", "sha256=" <> signature)
    end

    %{conn: conn, sign: sign}
  end

  test "refuses a delivery that is unsigned or signed with another secret", %{conn: conn} do
    body = Jason.encode!(%{"zen" => "Keep it logically awesome."})

    unsigned = conn |> put_req_header("content-type", "application/json") |> post(~p"/webhooks/github", body)
    assert json_response(unsigned, 401)["error"] == "Invalid signature"

    forged =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-hub-signature-256", "sha256=" <> String.duplicate("0", 64))
      |> post(~p"/webhooks/github", body)

    assert json_response(forged, 401)["error"] == "Invalid signature"
  end

  test "mirrors an issue a signed delivery reports for a GitHub-tracked project", %{
    conn: conn,
    sign: sign,
    github_project: %{id: project_id}
  } do
    issue = github_issue_json(%{"number" => 77, "title" => "Filed on GitHub", "labels" => [%{"name" => "rail:todo"}]})

    body =
      Jason.encode!(%{
        "action" => "opened",
        "issue" => issue,
        "repository" => %{"full_name" => "example/test-gh"},
        "installation" => %{"id" => 1}
      })

    conn = conn |> sign.(body, "issues") |> post(~p"/webhooks/github", body)

    assert json_response(conn, 200) == %{"received" => true}

    assert %Issue{identifier: "tgh#77", state: :todo, project_id: ^project_id} =
             Repo.get_by(Issue, external_id: issue["node_id"])
  end

  test "ignores a signed delivery for a repository, installation or tracker that is not one of Rail's", %{
    conn: conn,
    sign: sign,
    project: project
  } do
    for {repo, installation} <- [{"example/unknown", 1}, {"example/test-gh", 999}, {project.github_repo, 1}] do
      body =
        Jason.encode!(%{
          "action" => "opened",
          "issue" => github_issue_json(),
          "repository" => %{"full_name" => repo},
          "installation" => %{"id" => installation}
        })

      assert conn |> sign.(body, "issues") |> post(~p"/webhooks/github", body) |> json_response(200) == %{
               "ignored" => true
             }
    end

    ping = Jason.encode!(%{"zen" => "Anything added dilutes everything else."})
    assert conn |> sign.(ping, "ping") |> post(~p"/webhooks/github", ping) |> json_response(200) == %{"ignored" => true}
  end

  test "hands a Rail-tracked project only its pull requests, so its GitHub issues are never mirrored", %{
    conn: conn,
    sign: sign
  } do
    key = "Hook#{System.unique_integer([:positive])}"

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Rail-tracked",
        github_repo: "example/#{key}",
        github_installation_id: 1,
        tracker: :local,
        key: key,
        default_branch: "main",
        clone_path: "/tmp/#{key}"
      })

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{title: "Merged on GitHub"})
    %Issue{id: issue_id} = Repo.update!(Issue.pull_request_changeset(issue, %{pr_number: 12}))
    delivery = %{"repository" => %{"full_name" => "example/#{key}"}, "installation" => %{"id" => 1}}
    opened = Jason.encode!(Map.merge(delivery, %{"action" => "opened", "issue" => github_issue_json()}))

    assert conn |> sign.(opened, "issues") |> post(~p"/webhooks/github", opened) |> json_response(200) == %{
             "ignored" => true
           }

    merged =
      delivery
      |> Map.merge(%{
        "action" => "closed",
        "pull_request" => %{"merged" => true, "number" => 12, "head" => %{"ref" => "x"}, "base" => %{"ref" => "main"}}
      })
      |> Jason.encode!()

    assert conn |> sign.(merged, "pull_request") |> post(~p"/webhooks/github", merged) |> json_response(200) == %{
             "received" => true
           }

    assert %Issue{state: :done} = Repo.get!(Issue, issue_id)
  end

  test "ignores a Linear-tracked project's pull request", %{conn: conn, sign: sign, project: project} do
    body =
      Jason.encode!(%{
        "action" => "closed",
        "pull_request" => %{"merged" => true, "number" => 12, "head" => %{"ref" => "x"}, "base" => %{"ref" => "main"}},
        "repository" => %{"full_name" => project.github_repo},
        "installation" => %{"id" => project.github_installation_id}
      })

    assert conn |> sign.(body, "pull_request") |> post(~p"/webhooks/github", body) |> json_response(200) == %{
             "ignored" => true
           }
  end
end
