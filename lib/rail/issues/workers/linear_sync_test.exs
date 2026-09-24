defmodule Rail.Issues.Workers.LinearSyncTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Repo
  alias Rail.Users

  setup %{project: project} do
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
      assert %{"teamKey" => "TST", "after" => nil} = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [
              %{
                "id" => "lin_existing",
                "identifier" => "SPI-1",
                "title" => "New title",
                "priority" => 0,
                "state" => %{"id" => "st_2", "name" => "In Progress", "type" => "started"},
                # Linear sends milliseconds; the column holds seconds.
                "completedAt" => "2026-09-11T19:49:42.614Z"
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

    assert :ok = perform_job(LinearSync, %{project_id: project.id})

    assert %Issue{
             id: ^existing_id,
             title: "New title",
             state: :in_progress,
             priority: :medium,
             completed_at: ~U[2026-09-11 19:49:42Z]
           } = Repo.get_by(Issue, external_id: "lin_existing")

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

    assert_enqueued(worker: LinearSync, args: %{project_id: project_id, cursor: "cursor_2"})

    # Pulling from Linear is not a change to push back to it.
    refute_enqueued(worker: SyncIssue)
  end

  test "writes each issue's comments with replies threaded by Rail id, and re-syncs in place", %{project: project} do
    {:ok, %{id: author_id} = author} =
      Users.register_oauth_user(%{
        github_id: "gh_sync_commenter",
        login: "sync_commenter",
        email: "commenter@example.com"
      })

    author |> Ecto.Changeset.change(linear_user_id: "lin_usr_commenter") |> Repo.update!()

    page = fn body ->
      fn conn ->
        Req.Test.json(conn, %{
          "data" => %{
            "issues" => %{
              "nodes" => [
                %{
                  "id" => "lin_discussed",
                  "identifier" => "SPI-9",
                  "title" => "Discussed",
                  "state" => %{"id" => "st_1", "name" => "Todo", "type" => "unstarted"},
                  "comments" => %{
                    "nodes" => [
                      # Linear lists newest first, so the reply comes before its thread.
                      %{
                        "id" => "lin_reply",
                        "body" => "yes",
                        "createdAt" => "2026-09-09T11:00:00.000Z",
                        "parent" => %{"id" => "lin_thread"},
                        "user" => %{"id" => "lin_usr_commenter", "name" => "michael"}
                      },
                      %{
                        "id" => "lin_thread",
                        "body" => body,
                        "createdAt" => "2026-09-09T10:00:00.000Z",
                        "user" => %{
                          "id" => "lin_usr_elsewhere",
                          "name" => "paulo",
                          "avatarUrl" => "https://avatars/p.png"
                        }
                      }
                    ]
                  }
                }
              ]
            }
          }
        })
      end
    end

    Req.Test.expect(Rail.Linear, page.("Open question"))
    assert :ok = perform_job(LinearSync, %{project_id: project.id})

    assert %Issue{id: issue_id} = Repo.get_by(Issue, external_id: "lin_discussed")

    assert %Comment{
             id: thread_id,
             issue_id: ^issue_id,
             parent_id: nil,
             body: "Open question",
             author_user_id: nil,
             author_name: "paulo",
             author_avatar_url: "https://avatars/p.png",
             inserted_at: ~U[2026-09-09 10:00:00.000000Z]
           } = Repo.get_by(Comment, external_id: "lin_thread")

    assert %Comment{parent_id: ^thread_id, author_user_id: ^author_id} = Repo.get_by(Comment, external_id: "lin_reply")

    Req.Test.expect(Rail.Linear, page.("Edited question"))
    assert :ok = perform_job(LinearSync, %{project_id: project.id})

    assert %Comment{id: ^thread_id, body: "Edited question"} = Repo.get_by(Comment, external_id: "lin_thread")
    assert 2 = Repo.aggregate(Comment, :count)
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

    assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_2"})

    assert_receive {:issues_synced, ^project_id}
    refute_enqueued(worker: LinearSync)
  end

  test "maps Linear's state types onto Rail's", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      nodes =
        for {type, n} <-
              Enum.with_index(["triage", "backlog", "unstarted", "started", "completed", "canceled", "duplicate", "odd"]) do
          %{
            "id" => "lin_state_#{n}",
            "identifier" => "SPI-#{100 + n}",
            "title" => "State #{type}",
            "state" => %{"id" => "st_#{n}", "name" => type, "type" => type}
          }
        end

      Req.Test.json(conn, %{"data" => %{"issues" => %{"nodes" => nodes}}})
    end)

    assert :ok = perform_job(LinearSync, %{project_id: project.id})

    assert %{
             "State triage" => :triage,
             "State backlog" => :backlog,
             "State unstarted" => :backlog,
             "State started" => :in_progress,
             "State completed" => :done,
             "State canceled" => :canceled,
             "State duplicate" => :duplicate,
             "State odd" => :backlog
           } = Issue |> Repo.all() |> Map.new(&{&1.title, &1.state})
  end

  test "an issue synced as Backlog before Rail knew Duplicate is corrected and leaves the default list", %{
    project: project
  } do
    %Issue{id: issue_id} =
      %Issue{}
      |> Issue.linear_changeset(%{
        project_id: project.id,
        external_id: "lin_was_backlog",
        identifier: "SPI-50",
        title: "Marked duplicate",
        state: :backlog,
        state_name: "Duplicate"
      })
      |> Repo.insert!()

    assert %{issues: [%Issue{id: ^issue_id}]} = Issues.list_issues(project_id: project.id)

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issues" => %{
            "nodes" => [
              %{
                "id" => "lin_was_backlog",
                "identifier" => "SPI-50",
                "title" => "Marked duplicate",
                "state" => %{"id" => "st_dup", "name" => "Duplicate", "type" => "duplicate"}
              }
            ]
          }
        }
      })
    end)

    assert :ok = perform_job(LinearSync, %{project_id: project.id})

    assert %Issue{id: ^issue_id, state: :duplicate, state_name: "Duplicate"} =
             Repo.get_by(Issue, external_id: "lin_was_backlog")

    assert %{issues: [], total: 0} = Issues.list_issues(project_id: project.id)
  end

  test "a Linear failure fails the job so the page is retried", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "Linear Server Down"})
    end)

    assert {:error, {:linear_api_error, 500, %{"error" => "Linear Server Down"}}} =
             perform_job(LinearSync, %{project_id: project.id})
  end

  test "a project that is gone needs no sync" do
    # No Linear stub is queued, so a request would raise.
    assert :ok = perform_job(LinearSync, %{project_id: "prj_missing"})
  end
end
