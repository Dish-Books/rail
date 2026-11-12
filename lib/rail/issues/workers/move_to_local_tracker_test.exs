defmodule Rail.Issues.Workers.MoveToLocalTrackerTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Clients.R2
  alias Rail.Issues.Schemas.ClosedCycleIssue
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Cycle
  alias Rail.Issues.Schemas.CycleDay
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueLink
  alias Rail.Issues.Schemas.IssueRelation
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users

  @shot "https://uploads.linear.app/org/a1/shot.png"
  @spec_file "https://uploads.linear.app/org/att/spec"
  @gone "https://uploads.linear.app/org/gone/old.png"

  setup do
    stub(Date, :utc_today, fn -> ~D[2026-11-12] end)

    project =
      Repo.insert!(%Project{
        name: "Move Project",
        github_repo: "org/move-project",
        github_installation_id: 1,
        default_branch: "main",
        key: "mvw",
        linear_team_id: "lin_team_mvw",
        linear_state_ids: %{"todo" => "st_todo"},
        linear_workspace_id: "lw_test_seed",
        clone_path: "/tmp/repos/move-project"
      })

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "gh_move_owner", login: "move_owner", email: "move_owner@example.com"})

    user = user |> Ecto.Changeset.change(linear_user_id: "lin_usr_owner") |> Repo.update!()

    # Rail already holds one of the team's tickets, and one that moved here from another team for its task.
    existing =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_3",
        identifier: "MVW-3",
        title: "Old copy",
        state: :todo
      })
      |> Repo.insert!()

    foreign =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project.id,
        external_id: "lin_old4",
        identifier: "OLD-4",
        title: "From another team",
        state: :todo
      })
      |> Repo.insert!()

    # Another team's ticket Rail holds in another project.
    held =
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: "prj_test_seed",
        external_id: "lin_oth_held",
        identifier: "OTH-9",
        title: "Held elsewhere",
        state: :todo
      })
      |> Repo.insert!()

    state = fn type, name -> %{"id" => "st_#{name}", "name" => name, "type" => type} end

    issues_page_1 = [
      %{
        "id" => "lin_1",
        "identifier" => "MVW-1",
        "title" => "First",
        "description" => "See ![shot](#{@shot}) here",
        "priority" => 2,
        "estimate" => 3,
        "assignee" => %{"id" => "lin_usr_owner"},
        "state" => state.("started", "In Review"),
        "cycle" => %{"id" => "cyc_40"},
        "parent" => nil,
        "branchName" => "mvw-1-first",
        "url" => "https://linear.app/org/issue/MVW-1",
        "relations" => %{
          "nodes" => [
            %{"type" => "blocks", "relatedIssue" => %{"id" => "lin_2", "identifier" => "MVW-2"}},
            %{
              "type" => "blocks",
              "relatedIssue" => %{"id" => "lin_oth_2", "identifier" => "OTH-2", "url" => "https://linear.app/o/OTH-2"}
            },
            %{
              "type" => "related",
              "relatedIssue" => %{"id" => "lin_oth_1", "identifier" => "OTH-1", "url" => "https://linear.app/o/OTH-1"}
            },
            %{
              "type" => "duplicate",
              "relatedIssue" => %{"id" => "lin_5", "identifier" => "MVW-5", "url" => "https://linear.app/o/MVW-5"}
            }
          ]
        },
        "inverseRelations" => %{"nodes" => []},
        "attachments" => %{
          "nodes" => [
            %{"title" => "Spec", "url" => @spec_file},
            %{"title" => nil, "url" => "https://github.com/org/repo/pull/7"},
            %{"title" => "Same PR", "url" => "https://github.com/org/repo/pull/7"}
          ]
        }
      },
      %{
        "id" => "lin_2",
        "identifier" => "MVW-2",
        "title" => "Second",
        "description" => "Lost ![old](#{@gone})",
        "priority" => 0,
        "state" => state.("unstarted", "Todo"),
        "cycle" => %{"id" => "cyc_41"},
        "parent" => %{"id" => "lin_1"},
        "branchName" => "mvw-2-second",
        "archivedAt" => "2026-11-01T10:00:00.000Z",
        "relations" => %{"nodes" => []},
        "inverseRelations" => %{
          "nodes" => [
            %{"type" => "blocks", "issue" => %{"id" => "lin_1", "identifier" => "MVW-1"}},
            %{"type" => "blocks", "issue" => %{"id" => "lin_oth_held", "identifier" => "OTH-9"}},
            %{"type" => "similar", "issue" => %{"id" => "lin_3", "identifier" => "MVW-3"}}
          ]
        },
        "attachments" => %{"nodes" => []}
      }
    ]

    issues_page_2 = [
      %{
        "id" => "lin_3",
        "identifier" => "MVW-3",
        "title" => "Third",
        "state" => state.("canceled", "Duplicate"),
        "cycle" => nil,
        "parent" => nil,
        "branchName" => "mvw-3-third"
      },
      %{
        "id" => "lin_5",
        "identifier" => "MVW-5",
        "title" => "Fifth",
        "state" => state.("completed", "Done"),
        "cycle" => %{"id" => "cyc_40"},
        "parent" => nil,
        "branchName" => "mvw-5-fifth",
        "completedAt" => "2026-10-30T10:00:00.000Z",
        "archivedAt" => "2026-11-05T10:00:00.000Z",
        "inverseRelations" => %{
          "nodes" => [%{"type" => "duplicate", "issue" => %{"id" => "lin_1", "identifier" => "MVW-1"}}]
        }
      },
      %{"id" => "lin_trash", "identifier" => "MVW-6", "title" => "Trashed", "trashed" => true}
    ]

    comment = fn n, parent ->
      %{
        "id" => "lin_com_#{n}",
        "body" => "Comment #{n}",
        "createdAt" => "2026-10-0#{rem(n, 9) + 1}T10:00:00.000Z",
        "user" => %{"id" => "lin_usr_owner", "name" => "Owner", "avatarUrl" => "https://avatars.example/o.png"},
        "parent" => parent && %{"id" => "lin_com_#{parent}"},
        "issue" => %{"id" => "lin_1"}
      }
    end

    # Sixty on one ticket across two pages, ten of them replies, one with a file the description has too, and one on a
    # ticket the export lacks.
    comments_page_1 = for n <- 1..50, do: comment.(n, nil)

    comments_page_2 =
      [%{comment.(51, 1) | "body" => "Again ![shot](#{@shot})"} | for(n <- 52..60, do: comment.(n, n - 50))] ++
        [%{comment.(61, nil) | "issue" => %{"id" => "lin_missing"}}]

    cycle = fn number, starts, ends, history ->
      Map.merge(
        %{
          "id" => "cyc_#{number}",
          "number" => number,
          "startsAt" => "#{starts}T00:00:00.000Z",
          "endsAt" => "#{ends}T00:00:00.000Z",
          "scopeHistory" => [],
          "inProgressScopeHistory" => [],
          "completedScopeHistory" => [],
          "uncompletedIssuesUponClose" => %{"nodes" => []}
        },
        history
      )
    end

    cycles = [
      cycle.(40, "2026-10-26", "2026-11-02", %{
        "completedAt" => "2026-11-02T00:00:00.000Z",
        "scopeHistory" => [3.0, 5.0, 5.0],
        "inProgressScopeHistory" => [0.0, 3.0],
        "completedScopeHistory" => [0.0, 0.0, 2.0],
        "uncompletedIssuesUponClose" => %{"nodes" => [%{"id" => "lin_2"}, %{"id" => "lin_unknown"}]}
      }),
      cycle.(41, "2026-11-02", "2026-11-16", %{"scopeHistory" => [8.0], "completedScopeHistory" => [1.0]}),
      cycle.(42, "2026-11-16", "2026-11-30", %{}),
      cycle.(43, "2026-11-30", "2026-12-14", %{})
    ]

    page = fn connection, nodes, next ->
      %{connection => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => next != nil, "endCursor" => next}}}
    end

    graphql = fn conn, %{"query" => query, "variables" => %{"teamId" => "lin_team_mvw"} = variables} ->
      data =
        cond do
          query =~ "ExportIssues" and variables["after"] == nil ->
            %{"team" => Map.put(page.("issues", issues_page_1, "iss_2"), "key", "MVW")}

          query =~ "ExportIssues" ->
            %{"team" => Map.put(page.("issues", issues_page_2, nil), "key", "MVW")}

          query =~ "ExportComments" and variables["after"] == nil ->
            page.("comments", comments_page_1, "com_2")

          query =~ "ExportComments" ->
            page.("comments", comments_page_2, nil)

          query =~ "ExportCycles" ->
            %{"team" => page.("cycles", cycles, nil)}
        end

      Req.Test.json(conn, %{"data" => data})
    end

    linear = fn conn ->
      case conn.host do
        "uploads.linear.app" when conn.request_path == "/org/gone/old.png" ->
          Plug.Conn.send_resp(conn, 404, "Not found")

        "uploads.linear.app" ->
          conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, "FILE #{conn.request_path}")

        "api.linear.app" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          graphql.(conn, Jason.decode!(body))
      end
    end

    Req.Test.stub(Rail.Linear, linear)

    test_pid = self()

    r2 = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:r2_put, conn.request_path, body})
      Plug.Conn.send_resp(conn, 200, "")
    end

    Req.Test.stub(R2, r2)

    %{
      project: project,
      user: user,
      existing: existing,
      foreign: foreign,
      held: held,
      linear: linear,
      graphql: graphql,
      r2: r2
    }
  end

  test "moves every ticket with its comments and files into Rail and flips the project", %{
    project: %Project{id: project_id} = project,
    user: %{id: user_id},
    existing: %Issue{id: existing_id},
    foreign: %Issue{id: foreign_id}
  } do
    Phoenix.PubSub.subscribe(Rail.PubSub, "projects")
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")
    Phoenix.PubSub.subscribe(Rail.PubSub, "cycles")
    {:ok, _job} = Issues.move_to_local_tracker(user_scope(admin: true), project)

    assert %{success: 1, discard: 0} = Oban.drain_queue(queue: :issues)

    assert %Project{tracker: :local, key: "MVW", linear_team_id: nil, linear_state_ids: %{}, linear_workspace_id: nil} =
             Repo.get!(Project, project_id)

    assert_receive {:project_changed, ^project_id}
    assert_receive {:issues_synced, ^project_id}
    assert_receive {:cycles_changed, ^project_id}
    refute_enqueued(worker: SyncIssue)
    refute_enqueued(worker: AdvanceTrackerState)

    base = RailWeb.Endpoint.url() <> "/issues/"
    issues = Map.new(Repo.all(from(i in Issue, where: i.project_id == ^project_id)), &{&1.external_id, &1})
    assert Enum.sort(Map.keys(issues)) == ["lin_1", "lin_2", "lin_3", "lin_5", "lin_old4"]

    assert %Issue{
             id: first_id,
             tracker: :local,
             identifier: "MVW-1",
             number: 1,
             title: "First",
             state: :in_review,
             state_name: "In Review",
             priority: :high,
             estimate: 3,
             owner_user_id: ^user_id,
             branch_name: "mvw-1-first",
             description: description
           } = issues["lin_1"]

    assert issues["lin_1"].url == base <> first_id
    assert ["See ![shot](" <> shot_url, ""] = String.split(description, ") here")
    assert shot_url =~ ~r"\A#{Regex.escape(base <> first_id)}/assets/[0-9a-f-]{36}-shot\.png\z"

    assert %Issue{
             identifier: "MVW-2",
             number: 2,
             state: :todo,
             state_name: "Todo",
             parent_external_id: "lin_1",
             archived_at: ~U[2026-11-01 10:00:00Z],
             description: "Lost ![old](" <> @gone <> ")"
           } = issues["lin_2"]

    assert %Issue{id: ^existing_id, title: "Third", state: :duplicate, state_name: "Duplicate", cycle_external_id: nil} =
             issues["lin_3"]

    assert %Issue{number: 5, state: :done, archived_at: ~U[2026-11-05 10:00:00Z]} = issues["lin_5"]
    assert %Issue{id: ^foreign_id, tracker: :local, identifier: "MVW-6", number: 6} = issues["lin_old4"]

    # One copy for each ticket and file, though the description and a comment both show it; Linear's lost file is left.
    assert_received {:r2_put, "/r2_bucket/" <> shot_key, "FILE /org/a1/shot.png"}
    assert_received {:r2_put, "/r2_bucket/" <> _spec_key, "FILE /org/att/spec"}
    refute_received {:r2_put, _path, _body}
    assert String.starts_with?(shot_key, first_id <> "/")

    comments = Repo.all(from(c in Comment, where: c.issue_id == ^first_id, preload: :parent))
    assert length(comments) == 60
    replies = Enum.filter(comments, & &1.parent)
    assert length(replies) == 10

    assert Enum.all?(
             replies,
             &(&1.parent.external_id ==
                 "lin_com_#{String.to_integer(String.trim_leading(&1.external_id, "lin_com_")) - 50}")
           )

    assert Enum.all?(comments, &(&1.author_user_id == user_id and &1.author_name == "Owner"))
    expected_body = "Again ![shot](#{shot_url})"
    assert %Comment{body: ^expected_body} = Enum.find(comments, &(&1.external_id == "lin_com_51"))
    refute Repo.get_by(Comment, external_id: "lin_com_61")
  end

  test "moves every cycle with its history and closed tickets, and the nightly run carries on from it", %{
    project: %Project{id: project_id} = project
  } do
    {:ok, _job} = Issues.move_to_local_tracker(user_scope(admin: true), project)

    assert %{success: 1} = Oban.drain_queue(queue: :issues)

    cycles = Map.new(Repo.all(from(c in Cycle, where: c.project_id == ^project_id)), &{&1.number, &1})

    assert %{
             40 => %Cycle{id: cycle_40, starts_on: ~D[2026-10-26], ends_on: ~D[2026-11-01]},
             41 => %Cycle{id: cycle_41, starts_on: ~D[2026-11-02], ends_on: ~D[2026-11-15]},
             42 => %Cycle{starts_on: ~D[2026-11-16], ends_on: ~D[2026-11-29]},
             43 => %Cycle{}
           } = cycles

    issues = Map.new(Repo.all(from(i in Issue, where: i.project_id == ^project_id)), &{&1.external_id, &1})
    assert %Issue{id: first_id, cycle_external_id: ^cycle_40} = issues["lin_1"]
    assert %Issue{id: second_id, cycle_external_id: ^cycle_41} = issues["lin_2"]
    assert %Issue{id: fifth_id, cycle_external_id: ^cycle_40} = issues["lin_5"]

    days = fn cycle_id ->
      Repo.all(
        from(d in CycleDay,
          where: d.cycle_id == ^cycle_id,
          order_by: d.day,
          select: {d.day, d.scope, d.started, d.completed}
        )
      )
    end

    # A day past Linear's history repeats its last value, and started counts done work.
    assert [
             {~D[2026-10-26], 3, 0, 0},
             {~D[2026-10-27], 5, 3, 0},
             {~D[2026-10-28], 5, 5, 2},
             {~D[2026-10-29], 5, 5, 2},
             {~D[2026-10-30], 5, 5, 2},
             {~D[2026-10-31], 5, 5, 2},
             {~D[2026-11-01], 5, 5, 2}
           ] = days.(cycle_40)

    assert [{~D[2026-11-02], 8, 1, 1} | _rest] = running_days = days.(cycle_41)
    assert {~D[2026-11-11], 8, 1, 1} = List.last(running_days)
    assert length(running_days) == 10

    closed = Repo.all(from(c in ClosedCycleIssue, where: c.cycle_id == ^cycle_40, select: {c.issue_id, c.state}))
    assert Enum.sort(closed) == Enum.sort([{first_id, :in_review}, {fifth_id, :done}, {second_id, :todo}])

    # The next nightly run adds only yesterday, schedules no cycle and closes no ended one again.
    assert :ok = Issues.close_cycle_day(~D[2026-11-13])
    assert [{~D[2026-11-12], _scope, _started, _completed}] = days.(cycle_41) -- running_days
    assert Repo.aggregate(from(c in Cycle, where: c.project_id == ^project_id), :count) == 4
    assert Repo.aggregate(from(c in ClosedCycleIssue, where: c.cycle_id == ^cycle_40), :count) == 3
  end

  test "a cycle Linear has not closed yet is left for the nightly run to close and roll over", %{
    project: %Project{id: project_id} = project
  } do
    stub(Date, :utc_today, fn -> ~D[2026-11-16] end)
    {:ok, _job} = Issues.move_to_local_tracker(user_scope(admin: true), project)

    assert %{success: 1} = Oban.drain_queue(queue: :issues)

    %Cycle{id: cycle_41} = Repo.get_by!(Cycle, project_id: project_id, number: 41)
    %Cycle{id: cycle_42} = Repo.get_by!(Cycle, project_id: project_id, number: 42)
    %Issue{id: second_id} = Repo.get_by!(Issue, external_id: "lin_2")

    refute Repo.exists?(from(c in ClosedCycleIssue, where: c.cycle_id == ^cycle_41))

    assert ~D[2026-11-14] =
             Repo.one(from(d in CycleDay, where: d.cycle_id == ^cycle_41, select: max(d.day)))

    assert :ok = Issues.close_cycle_day(~D[2026-11-17])

    assert ~D[2026-11-15] =
             Repo.one(from(d in CycleDay, where: d.cycle_id == ^cycle_41, select: max(d.day)))

    assert [{^second_id, :todo}] =
             Repo.all(from(c in ClosedCycleIssue, where: c.cycle_id == ^cycle_41, select: {c.issue_id, c.state}))

    assert %Issue{cycle_external_id: ^cycle_42} = Repo.get!(Issue, second_id)
  end

  test "moves blockers and links, and the next ticket filed is numbered one past the highest", %{
    project: %Project{id: project_id} = project,
    existing: %Issue{id: existing_id},
    held: %Issue{id: held_id}
  } do
    {:ok, _job} = Issues.move_to_local_tracker(user_scope(admin: true), project)

    assert %{success: 1} = Oban.drain_queue(queue: :issues)

    issues = Map.new(Repo.all(from(i in Issue, where: i.project_id == ^project_id)), &{&1.external_id, &1})
    %Issue{id: first_id} = issues["lin_1"]
    %Issue{id: second_id} = issues["lin_2"]
    %Issue{id: fifth_id} = issues["lin_5"]

    assert [%IssueRelation{blocker_issue_id: ^first_id, blocked_issue_id: ^second_id}] =
             Repo.all(from(r in IssueRelation, where: r.project_id == ^project_id))

    links = fn issue_id ->
      Enum.sort(Repo.all(from(l in IssueLink, where: l.issue_id == ^issue_id, select: {l.title, l.url})))
    end

    base = RailWeb.Endpoint.url() <> "/issues/"
    spec_url = base <> first_id <> "/assets/"
    fifth_url = base <> fifth_id
    first_url = base <> first_id
    held_url = base <> held_id
    third_url = base <> existing_id

    # Each link points at the other ticket's Rail page where Rail holds it, and a URL the ticket already has is skipped.
    assert [
             {"Blocks OTH-2", "https://linear.app/o/OTH-2"},
             {"Duplicate of MVW-5", ^fifth_url},
             {"Related to OTH-1", "https://linear.app/o/OTH-1"},
             {"Spec", ^spec_url <> _spec_name},
             {"https://github.com/org/repo/pull/7", "https://github.com/org/repo/pull/7"}
           ] = links.(first_id)

    assert [{"Blocked by OTH-9", ^held_url}, {"Similar to MVW-3", ^third_url}] = links.(second_id)
    assert [{"Duplicated by MVW-1", ^first_url}] = links.(fifth_id)

    # A ticket filed from the project as a page loaded before the move held it goes to Rail, after the highest number.
    Req.Test.stub(Rail.Linear, fn _conn -> flunk("Linear was asked after the move") end)

    assert {:ok, %Issue{tracker: :local, identifier: "MVW-7", number: 7}} =
             Issues.create_issue(system_scope(), project, %{title: "After the move"})
  end

  test "a file Linear's own token cannot fetch stops the move before anything is written", %{
    project: %Project{id: project_id} = project,
    linear: linear
  } do
    Req.Test.stub(Rail.Linear, fn
      %Plug.Conn{host: "uploads.linear.app"} = conn -> Plug.Conn.send_resp(conn, 403, "Forbidden")
      conn -> linear.(conn)
    end)

    {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(user_scope(admin: true), project)

    assert %{discard: 1} = Oban.drain_queue(queue: :issues)

    assert %Oban.Job{
             meta: %{
               "failure" =>
                 "Linear answered 403 for a file on MVW-1 (https://uploads.linear.app/org/a1/shot.png), so nothing was written."
             }
           } = Repo.get!(Oban.Job, job_id)

    assert %Project{tracker: :linear} = Repo.get!(Project, project_id)
  end

  test "a 502 on a later page leaves the project on Linear as it was, and its row says why", %{
    project: %Project{id: project_id} = project,
    existing: %Issue{id: existing_id},
    graphql: graphql
  } do
    Req.Test.stub(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode!(body) do
        %{"query" => "query ExportComments" <> _rest, "variables" => %{"after" => "com_2"}} ->
          Plug.Conn.send_resp(conn, 502, "Bad gateway")

        request ->
          graphql.(conn, request)
      end
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "projects")
    {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(user_scope(admin: true), project)
    assert_receive {:project_changed, ^project_id}

    assert %{discard: 1} = Oban.drain_queue(queue: :issues)

    assert %Oban.Job{
             state: "discarded",
             meta: %{"failure" => "Linear answered 502 while reading comments, so nothing was written."}
           } = Repo.get!(Oban.Job, job_id)

    assert_receive {:project_changed, ^project_id}

    assert %Project{tracker: :linear, key: "mvw", linear_team_id: "lin_team_mvw"} =
             project = Repo.get!(Project, project_id)

    assert %Issue{id: ^existing_id, tracker: :linear, title: "Old copy"} = Repo.get_by(Issue, external_id: "lin_3")
    refute Repo.get_by(Issue, external_id: "lin_1")
    refute Repo.exists?(from(c in Cycle, where: c.project_id == ^project_id))
    refute_received {:r2_put, _path, _body}

    assert {:ok, %{^project_id => {:stopped, "Linear answered 502 while reading comments, so nothing was written."}}} =
             Issues.list_tracker_moves(user_scope(admin: true), [project])
  end

  test "each way Linear or R2 can stop the move is recorded as the sentence its row shows", %{
    project: %Project{id: project_id} = project,
    graphql: graphql,
    linear: linear
  } do
    stops = [
      {fn
         %Plug.Conn{host: "api.linear.app"} = conn ->
           Req.Test.json(conn, %{"errors" => [%{"message" => "Entity not found"}]})
       end, R2, nil, "Linear refused the request while reading tickets (Entity not found), so nothing was written."},
      {fn %Plug.Conn{host: "api.linear.app"} = conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)

         case Jason.decode!(body) do
           %{"query" => "query ExportCycles" <> _rest} -> Req.Test.transport_error(conn, :econnrefused)
           request -> graphql.(conn, request)
         end
       end, R2, nil, "The move stopped while reading cycles (connection refused), so nothing was written."},
      {fn %Plug.Conn{host: "api.linear.app"} = conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)

         case Jason.decode!(body) do
           %{"query" => "query ExportComments" <> _rest} -> Req.Test.json(conn, %{"errors" => [%{}]})
           request -> graphql.(conn, request)
         end
       end, R2, nil, "The move stopped while reading comments ({:linear_graphql_error, [%{}]}), so nothing was written."},
      {linear, R2, &Plug.Conn.send_resp(&1, 500, "InternalError"),
       "Rail's file storage answered 500 while copying files, so nothing was written."}
    ]

    for {linear_stub, r2, r2_stub, sentence} <- stops do
      Req.Test.stub(Rail.Linear, linear_stub)
      if r2_stub, do: Req.Test.stub(r2, r2_stub)
      {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(user_scope(admin: true), project)

      assert %{discard: 1} = Oban.drain_queue(queue: :issues)
      assert %Oban.Job{meta: %{"failure" => ^sentence}} = Repo.get!(Oban.Job, job_id)
      assert %Project{tracker: :linear} = Repo.get!(Project, project_id)
    end

    {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(user_scope(admin: true), project)
    Repo.update_all(from(p in Project, where: p.id == ^project_id), set: [linear_workspace_id: nil])

    assert %{discard: 1} = Oban.drain_queue(queue: :issues)

    assert %Oban.Job{
             meta: %{"failure" => "Rail has no Linear token for this project's workspace, so nothing was written."}
           } = Repo.get!(Oban.Job, job_id)
  end

  test "a project another move already took off Linear is left alone", %{
    project: %Project{id: project_id} = project
  } do
    {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(user_scope(admin: true), project)
    Repo.update_all(from(p in Project, where: p.id == ^project_id), set: [tracker: :local])

    assert %{discard: 1} = Oban.drain_queue(queue: :issues)

    assert %Oban.Job{meta: %{"failure" => "The project had already left Linear, so nothing was written."}} =
             Repo.get!(Oban.Job, job_id)

    refute Repo.get_by(Issue, external_id: "lin_1")
    refute Repo.exists?(from(c in Cycle, where: c.project_id == ^project_id))
  end

  test "a ticket written under another id while its files were copied stops the move", %{
    project: %Project{id: project_id} = project,
    r2: r2
  } do
    Req.Test.stub(R2, fn conn ->
      %Issue{}
      |> Issue.tracker_changeset(%{
        project_id: project_id,
        external_id: "lin_1",
        identifier: "MVW-1",
        title: "Synced meanwhile",
        state: :todo
      })
      |> Repo.insert!(on_conflict: :nothing, conflict_target: :external_id)

      r2.(conn)
    end)

    {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(user_scope(admin: true), project)

    assert %{discard: 1} = Oban.drain_queue(queue: :issues)

    assert %Oban.Job{
             meta: %{"failure" => "A ticket changed in Rail while its files were copied, so nothing was written."}
           } =
             Repo.get!(Oban.Job, job_id)

    assert %Issue{tracker: :linear, title: "Synced meanwhile"} = Repo.get_by(Issue, external_id: "lin_1")
    assert %Project{tracker: :linear} = Repo.get!(Project, project_id)
    refute Repo.exists?(from(c in Cycle, where: c.project_id == ^project_id))
  end

  test "a team key another project already has stops the move with nothing written", %{
    project: %Project{id: project_id} = project
  } do
    # The team's key changed in Linear after the project was set up under its old one.
    Repo.update_all(from(p in Project, where: p.id == ^project_id), set: [key: "mvx"])

    Repo.insert!(%Project{
      name: "Upper Move Project",
      github_repo: "org/upper-move-project",
      github_installation_id: 1,
      default_branch: "main",
      key: "MVW",
      tracker: :local,
      clone_path: "/tmp/repos/upper-move-project"
    })

    {:ok, %Oban.Job{id: job_id}} = Issues.move_to_local_tracker(user_scope(admin: true), project)

    assert %{discard: 1} = Oban.drain_queue(queue: :issues)

    assert %Oban.Job{meta: %{"failure" => "Another project already has the key MVW, so nothing was written."}} =
             Repo.get!(Oban.Job, job_id)

    refute Repo.get_by(Issue, external_id: "lin_1")
    assert %Issue{tracker: :linear, identifier: "OLD-4"} = Repo.get_by(Issue, external_id: "lin_old4")
    assert %Project{tracker: :linear, key: "mvx"} = Repo.get!(Project, project_id)
  end
end
