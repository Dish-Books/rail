defmodule Rail.Learnings.Utils.EnqueuePullRequestsTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  import Rail.Learnings.Utils.EnqueuePullRequests

  alias Rail.GitHub.Client
  alias Rail.Learnings.Schemas.ProcessedPullRequest
  alias Rail.Learnings.Workers.CollectPullRequest

  setup do
    since = ~U[2026-10-01 06:00:00Z]

    page = fn numbers_merged, updated ->
      for {number, merged_at} <- numbers_merged,
          do: %{"number" => number, "merged_at" => merged_at, "updated_at" => updated}
    end

    %{since: since, page: page}
  end

  test "a window queues one job per PR merged in it, reading pages until they are older", %{
    project: project,
    since: since,
    page: page
  } do
    full = page.(for(n <- 1..100, do: {n, if(rem(n, 2) == 0, do: "2026-10-02T10:00:00Z")}), "2026-10-02T11:00:00Z")
    last = page.([{101, "2026-09-30T10:00:00Z"}, {102, "2026-10-01T07:00:00Z"}], "2026-09-30T11:00:00Z")

    Req.Test.stub(Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.request_path, conn.query_params["page"]} do
        {"/app/installations/" <> _rest, _page} -> Req.Test.json(conn, %{"token" => "ghs_token"})
        {"/repos/example/test-seed/pulls", "1"} -> Req.Test.json(conn, full)
        {"/repos/example/test-seed/pulls", "2"} -> Req.Test.json(conn, last)
      end
    end)

    Repo.insert!(%ProcessedPullRequest{project_id: project.id, number: 2})

    merged = Enum.concat(Enum.to_list(4..100//2), [102])
    assert {:ok, ^merged} = enqueue_pull_requests(project, since)
    assert length(all_enqueued(worker: CollectPullRequest)) == 50
    refute_enqueued(worker: CollectPullRequest, args: %{number: 2})
  end

  test "the backfill reads every page, and a failed listing queues nothing", %{project: project, page: page} do
    Req.Test.stub(Client, fn conn ->
      case conn.request_path do
        "/app/installations/" <> _rest ->
          Req.Test.json(conn, %{"token" => "ghs_token"})

        "/repos/example/test-seed/pulls" ->
          Req.Test.json(conn, page.([{5, "2020-01-01T00:00:00Z"}], "2020-01-01T00:00:00Z"))
      end
    end)

    assert {:ok, [5]} = enqueue_pull_requests(project, nil)

    Req.Test.stub(Client, &Req.Test.json(Plug.Conn.put_status(&1, 401), %{"message" => "Bad credentials"}))
    assert {:error, {:github_api_error, 401, _body}} = enqueue_pull_requests(project, nil)
  end

  test "the same PR queued from extraction, a window and the backfill while its job waits is one job", %{project: project} do
    assert {:ok, [7]} = enqueue_pull_requests(project, 7)
    assert {:ok, [7]} = enqueue_pull_requests(project, 7)

    assert [_one] = all_enqueued(worker: CollectPullRequest, args: %{project_id: project.id, number: 7})
  end
end
