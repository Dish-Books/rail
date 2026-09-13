defmodule Rail.Issues.Workers.SyncProjectIssuesTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Issues.Workers.SyncProjectIssues
  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Users

  setup do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_id"}]}}})
    end)

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Sync Project Issues Project",
        github_repo: "org/sync-project-issues",
        github_installation_id: 5511,
        linear_workspace: %{
          name: "Sync Project Issues Workspace",
          external_id: "lin_ws_sync_project_issues",
          token: "lin_api_token_sync_project_issues",
          webhook_secret: "whsec_sync_project_issues"
        },
        linear_team_key: "SPI",
        default_branch: "main",
        clone_path: "/tmp/repos/sync-project-issues"
      })

    %{project: project}
  end

  test "writes a page and queues the next one from its cursor", %{project: %{id: project_id} = project} do
    %Issue{id: existing_id} =
      %Issue{}
      |> Issue.changeset(%{
        project_id: project.id,
        external_id: "lin_existing",
        identifier: "SPI-1",
        title: "Old title",
        state: :triage
      })
      |> Repo.insert!()

    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_sync_assignee", login: "sync_assignee", email: "assignee@example.com"})

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_assignee") |> Repo.update!()

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"teamKey" => "SPI", "after" => nil} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [
              %{
                "id" => "lin_existing",
                "identifier" => "SPI-1",
                "title" => "New title",
                "priority" => 0,
                "state" => %{"id" => "st_2", "name" => "In Progress", "type" => "started"}
              },
              %{
                "id" => "lin_new",
                "identifier" => "SPI-2",
                "title" => "Brand new",
                "description" => "From Linear",
                "priority" => 1,
                "estimate" => 5,
                "assignee" => %{"id" => "lin_usr_assignee"},
                "state" => %{"id" => "st_1", "name" => "Todo", "type" => "unstarted"},
                "branchName" => "spi-2-brand-new",
                "url" => "https://linear.app/issue/SPI-2"
              }
            ],
            "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor_2"}
          }
        }
      })
    end)

    assert :ok = perform_job(SyncProjectIssues, %{project_id: project.id})

    assert %Issue{id: ^existing_id, title: "New title", state: :in_progress, priority: :medium} =
             Repo.get_by(Issue, external_id: "lin_existing")

    assert %Issue{
             project_id: ^project_id,
             identifier: "SPI-2",
             description: "From Linear",
             priority: :urgent,
             estimate: 5,
             state: :backlog,
             state_name: "Todo",
             owner_user_id: ^user_id,
             branch_name: "spi-2-brand-new",
             url: "https://linear.app/issue/SPI-2"
           } = Repo.get_by(Issue, external_id: "lin_new")

    assert_enqueued(worker: SyncProjectIssues, args: %{project_id: project_id, cursor: "cursor_2"})

    # Pulling from Linear is not a change to push back to it.
    refute_enqueued(worker: SyncIssue)
  end

  test "the last page announces the sync is done and queues nothing more", %{project: %{id: project_id}} do
    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"after" => "cursor_2"} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{"nodes" => [], "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
        }
      })
    end)

    assert :ok = perform_job(SyncProjectIssues, %{project_id: project_id, cursor: "cursor_2"})

    assert_receive {:issues_synced, ^project_id}
    refute_enqueued(worker: SyncProjectIssues)
  end

  test "maps Linear's state types onto Rail's", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      nodes =
        for {type, n} <- Enum.with_index(["triage", "backlog", "unstarted", "started", "completed", "canceled", "odd"]) do
          %{
            "id" => "lin_state_#{n}",
            "identifier" => "SPI-#{100 + n}",
            "title" => "State #{type}",
            "state" => %{"id" => "st_#{n}", "name" => type, "type" => type}
          }
        end

      Req.Test.json(conn, %{"data" => %{"issues" => %{"nodes" => nodes}}})
    end)

    assert :ok = perform_job(SyncProjectIssues, %{project_id: project.id})

    assert %{
             "State triage" => :triage,
             "State backlog" => :backlog,
             "State unstarted" => :backlog,
             "State started" => :in_progress,
             "State completed" => :done,
             "State canceled" => :canceled,
             "State odd" => :backlog
           } = Issue |> Repo.all() |> Map.new(&{&1.title, &1.state})
  end

  test "a Linear failure fails the job so the page is retried", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "Linear Server Down"})
    end)

    assert {:error, {:linear_api_error, 500, %{"error" => "Linear Server Down"}}} =
             perform_job(SyncProjectIssues, %{project_id: project.id})
  end

  test "a project that is gone needs no sync" do
    # No Linear stub is queued, so a request would raise.
    assert :ok = perform_job(SyncProjectIssues, %{project_id: "prj_missing"})
  end
end
