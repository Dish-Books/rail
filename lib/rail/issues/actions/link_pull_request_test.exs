defmodule Rail.Issues.Actions.LinkPullRequestTest do
  use Rail.DataCase, async: true

  alias Rail.GitHub.Client
  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue

  setup %{project: project} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_find_pr_1",
        identifier: "FPR-12",
        title: "Filter invoices by vendor",
        branch_name: "michael/fpr-12-filter-invoices-by-vendor",
        state: :in_progress
      })
      |> Repo.insert!()

    %{scope: system_scope(), issue: issue}
  end

  test "links the open pull request from the issue's own branch before one that only names it", %{
    scope: scope,
    issue: issue
  } do
    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/1/access_tokens" ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-seed/pulls" ->
          assert %{"state" => "open", "per_page" => "100"} = conn.query_params

          Req.Test.json(conn, [
            %{"number" => 3, "title" => "FPR-12 a first try", "head" => %{"ref" => "spike"}},
            %{
              "number" => 4,
              "title" => "Vendors",
              "html_url" => "https://github.com/example/test-seed/pull/4",
              "head" => %{"ref" => "michael/fpr-12-filter-invoices-by-vendor"}
            }
          ])
      end
    end)

    assert {:ok, %{"number" => 4}} = Issues.link_pull_request(scope, issue)

    assert %Issue{pr_number: 4, pr_url: "https://github.com/example/test-seed/pull/4", pr_title: "Vendors"} =
             Repo.reload!(issue)
  end

  test "reads a linked pull request again by its number, and looks for another once it has closed", %{
    scope: scope,
    issue: issue
  } do
    issue =
      issue
      |> Issue.pull_request_changeset(%{pr_number: 4, pr_url: "https://github.com/example/test-seed/pull/4"})
      |> Repo.update!()

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _id ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-seed/pulls/4" ->
          Req.Test.json(conn, %{"number" => 4, "state" => "open", "title" => "Renamed"})
      end
    end)

    assert {:ok, %{"number" => 4}} = Issues.link_pull_request(scope, issue)
    assert %Issue{pr_number: 4, pr_title: "Renamed"} = issue = Repo.reload!(issue)

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _id -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/example/test-seed/pulls/4" -> Req.Test.json(conn, %{"number" => 4, "state" => "closed"})
        "/repos/example/test-seed/pulls" -> Req.Test.json(conn, [])
      end
    end)

    assert {:ok, nil} = Issues.link_pull_request(scope, issue)
    assert %Issue{pr_number: nil, pr_url: nil, pr_title: nil} = Repo.reload!(issue)
  end

  test "finds one whose branch or title names the issue, and not one naming another", %{scope: scope, issue: issue} do
    for {pull_requests, found} <- [
          {[%{"number" => 5, "title" => "Vendor filter", "head" => %{"ref" => "FPR-12-vendors"}}], 5},
          {[%{"number" => 6, "title" => "[fpr-12] Vendor filter", "head" => %{"ref" => "vendors"}}], 6},
          {[%{"number" => 7, "title" => "FPR-123 and FPR-1", "head" => %{"ref" => "fpr-120"}}], nil},
          {[%{"number" => 8, "title" => nil, "head" => %{"ref" => "xfpr-12"}}], nil}
        ] do
      Req.Test.stub(Client, fn conn ->
        case conn.request_path do
          "/app/installations/" <> _id -> Req.Test.json(conn, %{"token" => "ghs_token"})
          "/repos/example/test-seed/pulls" -> Req.Test.json(conn, pull_requests)
        end
      end)

      assert {:ok, pull_request} = Issues.link_pull_request(scope, issue)
      assert (pull_request && pull_request["number"]) == found
    end
  end

  test "names a GitHub issue by its key and number", %{github_project: project, scope: scope} do
    issue =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        tracker: :github,
        external_id: "gh_find_pr_1",
        identifier: "tgh#31",
        number: 31,
        title: "Vendors",
        state: :in_progress
      })
      |> Repo.insert!()

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _id -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/example/test-gh/pulls" -> Req.Test.json(conn, [%{"number" => 9, "head" => %{"ref" => "tgh-31-vendors"}}])
      end
    end)

    assert {:ok, %{"number" => 9}} = Issues.link_pull_request(scope, issue)
  end

  test "says what GitHub refused, and finds nothing for an issue the user cannot see", %{scope: scope, issue: issue} do
    assert {:error, :not_found} = Issues.link_pull_request(user_scope(project_ids: []), issue)

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _id -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/example/test-seed/pulls" -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "no"})
      end
    end)

    assert {:error, {:github_api_error, 403, _body}} = Issues.link_pull_request(scope, issue)

    issue = issue |> Issue.pull_request_changeset(%{pr_number: 4}) |> Repo.update!()

    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _id -> Req.Test.json(conn, %{"token" => "ghs_token"})
        "/repos/example/test-seed/pulls/4" -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "no"})
      end
    end)

    assert {:error, {:github_api_error, 404, _body}} = Issues.link_pull_request(scope, issue)
    assert %Issue{pr_number: 4} = Repo.reload!(issue)
  end
end
