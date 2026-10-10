defmodule Rail.Issues.Workers.LinearSyncTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Issues
  alias Rail.Issues.Schemas.Comment
  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Workers.AdvanceTrackerState
  alias Rail.Issues.Workers.LinearSync
  alias Rail.Issues.Workers.SyncIssue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles
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
      assert %{"query" => query, "variables" => %{"teamKey" => "TST", "after" => nil}} = Jason.decode!(body)
      assert query =~ "includeArchived: true"
      assert query =~ "orderBy: createdAt"
      assert query =~ "archivedAt"
      assert query =~ "trashed"

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

    assert :ok = perform_job(LinearSync, %{project_id: project.id, started_at: "2026-10-06T10:00:00.000000Z"})

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

    assert_enqueued(
      worker: LinearSync,
      args: %{project_id: project_id, cursor: "cursor_2", started_at: "2026-10-06T10:00:00.000000Z"}
    )

    # Pulling from Linear is not a change to push back to it.
    refute_enqueued(worker: SyncIssue)
  end

  test "an unowned issue the page gives an owner has its Linear status caught up, and no other does", %{
    project: project
  } do
    {:ok, %{id: user_id} = user} =
      Users.register_oauth_user(%{github_id: "gh_sync_owner", login: "sync_owner", email: "sync_owner@example.com"})

    user |> Ecto.Changeset.change(linear_user_id: "lin_usr_sync_owner") |> Repo.update!()

    [%Issue{id: unowned_id} = unowned, owned, left_alone] =
      for {key, owner_user_id} <- [{"unowned", nil}, {"owned", user_id}, {"left_alone", nil}] do
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: "lin_sync_#{key}",
          identifier: "SPO-#{key}",
          title: "Issue #{key}",
          state: :backlog,
          owner_user_id: owner_user_id
        })
        |> Repo.insert!()
      end

    Req.Test.expect(Rail.Linear, fn conn ->
      nodes =
        for {issue, assignee} <- [
              {unowned, %{"id" => "lin_usr_sync_owner"}},
              {owned, %{"id" => "lin_usr_sync_owner"}},
              {left_alone, nil}
            ] do
          %{
            "id" => issue.external_id,
            "identifier" => issue.identifier,
            "title" => issue.title,
            "assignee" => assignee,
            "updatedAt" => "2026-10-08T15:00:00.250Z"
          }
        end

      Req.Test.json(conn, %{
        "data" => %{"issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}}
      })
    end)

    assert :ok = perform_job(LinearSync, %{project_id: project.id})

    assert %Issue{owner_user_id: ^user_id, external_updated_at: ~U[2026-10-08 15:00:00.250000Z]} = Repo.reload!(unowned)
    assert [%Oban.Job{args: %{"issue_id" => ^unowned_id}}] = all_enqueued(worker: AdvanceTrackerState)
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
      |> Issue.tracker_changeset(%{
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

  describe "the last page" do
    # Every finished sync of the seeded project reaches every subscriber, so these sync their own.
    setup %{project: seeded} do
      # Roles come with the seeded project only.
      {:ok, plan} = Roles.get_role(project_id: seeded.id, stage: :plan)

      Req.Test.expect(Rail.Linear, fn conn ->
        Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_sync"}]}}})
      end)

      {:ok, project} =
        Projects.create_project(system_scope(), %{
          name: "Last Page Project",
          github_repo: "org/last-page",
          github_installation_id: 12_954,
          key: "LPG",
          default_branch: "main",
          clone_path: create_temp_git_repo(prefix: "rail_last_page"),
          linear_workspace_id: "lw_test_seed"
        })

      insert = fn external_id, state ->
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project.id,
          external_id: external_id,
          identifier: external_id,
          title: external_id,
          state: state
        })
        |> Repo.insert!()
        |> Repo.preload(:project)
      end

      last_page = fn nodes ->
        Req.Test.expect(Rail.Linear, fn conn ->
          Req.Test.json(conn, %{
            "data" => %{
              "issues" => %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}}
            }
          })
        end)
      end

      # Each issue Rail looks up answers from `responses`, whatever order they are asked in.
      lookups = fn responses ->
        Req.Test.expect(Rail.Linear, map_size(responses), fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          %{"query" => "query Issue" <> _rest, "variables" => %{"id" => id}} = Jason.decode!(body)

          case Map.fetch!(responses, id) do
            respond when is_function(respond, 0) -> Req.Test.json(conn, respond.())
            response -> Req.Test.json(conn, response)
          end
        end)
      end

      not_found = %{"errors" => [%{"message" => "Entity not found: Issue"}], "data" => nil}

      %{project: project, plan: plan, insert: insert, last_page: last_page, lookups: lookups, not_found: not_found}
    end

    test "a Linear failure fails the job so the page is retried, removing and announcing nothing", %{
      project: %{id: project_id} = project
    } do
      %Issue{id: issue_id} =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: project_id,
          external_id: "lin_unlisted",
          identifier: "SPI-60",
          title: "Not listed yet",
          state: :todo
        })
        |> Repo.insert!()

      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      Req.Test.expect(Rail.Linear, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "Linear Server Down"})
      end)

      assert {:error, {:linear_api_error, 500, %{"error" => "Linear Server Down"}}} =
               perform_job(LinearSync, %{
                 project_id: project.id,
                 cursor: "cursor_last",
                 started_at: DateTime.to_iso8601(DateTime.utc_now())
               })

      assert %Issue{id: ^issue_id} = Repo.get(Issue, issue_id)
      refute_receive {:issues_synced, ^project_id}, 50
    end

    test "an issue with no task the pages no longer list is removed without asking Linear, then announced", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page
    } do
      %Issue{id: gone_id} = insert.("lin_gone", :todo)
      %Issue{id: listed_id} = insert.("lin_listed", :todo)
      started_at = DateTime.to_iso8601(DateTime.utc_now())
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      last_page.([%{"id" => "lin_listed", "identifier" => "SPI-61", "title" => "Listed", "archivedAt" => nil}])

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert Repo.get(Issue, gone_id) == nil
      assert %Issue{id: ^listed_id, title: "Listed"} = Repo.get(Issue, listed_id)
      assert_receive {:issues_synced, ^project_id}
    end

    test "an issue with a task the pages no longer list is kept when Linear finds it on another team", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page,
      lookups: lookups
    } do
      %Issue{id: moved_id} = moved = insert.("lin_moved", :in_progress)
      {:ok, %Task{id: task_id}} = Pipeline.create_task(moved, :engineer)
      started_at = DateTime.to_iso8601(DateTime.utc_now())

      last_page.([])

      lookups.(%{
        "lin_moved" => %{
          "data" => %{"issue" => %{"id" => "lin_moved", "trashed" => nil, "team" => %{"id" => "lin_team_other"}}}
        }
      })

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert %Issue{id: ^moved_id, project_id: ^project_id, identifier: "lin_moved"} = Repo.get(Issue, moved_id)
      assert %Task{issue_id: ^moved_id} = Repo.get(Task, task_id)
    end

    test "an issue with a task is removed with it and its worktree when Linear reports it trashed or not found", %{
      project: %{id: project_id, clone_path: clone_path},
      plan: plan,
      insert: insert,
      last_page: last_page,
      lookups: lookups,
      not_found: not_found
    } do
      tasks =
        for external_id <- ["lin_trashed", "lin_not_found", "lin_null"] do
          {:ok, %Task{} = task} = external_id |> insert.(:todo) |> Pipeline.create_task(:plan)
          task
        end

      worktree_path = Path.join(System.tmp_dir!(), "rail_pruned_wt_#{System.unique_integer([:positive])}")
      git!(clone_path, ["worktree", "add", "-b", "pruned-branch", worktree_path])

      {:ok, %Task{id: pruned_task_id}} =
        Pipeline.update_task(hd(tasks), %{worktree_name: "pruned-branch", worktree_path: worktree_path})

      {:ok, %Run{id: run_id}} =
        Pipeline.create_run(%{
          task_id: pruned_task_id,
          role_id: plan.id,
          status: :running,
          started_at: DateTime.utc_now()
        })

      started_at = DateTime.to_iso8601(DateTime.utc_now())
      Phoenix.PubSub.subscribe(Rail.PubSub, "sandboxes")
      last_page.([])

      lookups.(%{
        "lin_trashed" => %{"data" => %{"issue" => %{"id" => "lin_trashed", "trashed" => true}}},
        "lin_not_found" => not_found,
        "lin_null" => %{"data" => %{"issue" => nil}}
      })

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert [] = Repo.all(from(i in Issue, where: i.project_id == ^project_id))
      assert [] = Repo.all(from(t in Task, where: t.id in ^Enum.map(tasks, & &1.id)))
      refute File.exists?(worktree_path)
      assert "" = git!(clone_path, ["branch", "--list", "pruned-branch"])
      assert Repo.get(Run, run_id) == nil
      assert_receive :sandboxes_changed
    end

    test "a split parent Linear reports trashed is kept, with its children", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page,
      lookups: lookups
    } do
      {:ok, %Task{id: parent_id} = parent} = "lin_split_parent" |> insert.(:in_progress) |> Pipeline.create_task(:split)
      child_issue = insert.("lin_split_child", :todo)

      {:ok, %Task{id: child_id}} =
        Pipeline.create_child_task(parent, child_issue, %{number: 1, builds_on: [], plan: "## Implementation plan"})

      started_at = DateTime.to_iso8601(DateTime.utc_now())
      last_page.([])

      lookups.(%{
        "lin_split_parent" => %{"data" => %{"issue" => %{"id" => "lin_split_parent", "trashed" => true}}},
        "lin_split_child" => %{
          "data" => %{"issue" => %{"id" => "lin_split_child", "trashed" => nil, "team" => %{"id" => "lin_team_other"}}}
        }
      })

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert %Issue{} = Repo.get_by(Issue, external_id: "lin_split_parent")
      assert %Task{} = Repo.get(Task, parent_id)
      assert %Task{parent_task_id: ^parent_id} = Repo.get(Task, child_id)
    end

    test "a lookup that fails any other way fails the job, removing and announcing nothing", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page,
      lookups: lookups
    } do
      %Issue{id: tasked_id} = tasked = insert.("lin_limited", :todo)
      {:ok, _task} = Pipeline.create_task(tasked, :plan)
      %Issue{id: untasked_id} = insert.("lin_untasked", :todo)
      started_at = DateTime.to_iso8601(DateTime.utc_now())
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      last_page.([])
      lookups.(%{"lin_limited" => %{"errors" => [%{"message" => "Rate limit exceeded"}]}})

      assert {:error, {:linear_graphql_error, [%{"message" => "Rate limit exceeded"}]}} =
               perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert %Issue{id: ^tasked_id} = Repo.get(Issue, tasked_id)
      assert %Issue{id: ^untasked_id} = Repo.get(Issue, untasked_id)
      refute_receive {:issues_synced, ^project_id}, 50
    end

    test "an archived node is written only with a task, and the one without is removed", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page
    } do
      %Issue{id: kept_id} = kept = insert.("lin_archived_kept", :in_review)
      {:ok, %Task{id: task_id}} = Pipeline.create_task(kept, :review)
      %Issue{id: dropped_id} = insert.("lin_archived_dropped", :done)
      started_at = DateTime.to_iso8601(DateTime.utc_now())

      archived = fn external_id ->
        %{
          "id" => external_id,
          "identifier" => external_id,
          "title" => "Archived #{external_id}",
          "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"},
          "archivedAt" => "2026-10-06T09:00:00.000Z",
          "trashed" => nil
        }
      end

      last_page.([archived.("lin_archived_kept"), archived.("lin_archived_dropped"), archived.("lin_archived_new")])

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert %Issue{id: ^kept_id, title: "Archived lin_archived_kept", state: :done} = Repo.get(Issue, kept_id)
      assert %Task{issue_id: ^kept_id} = Repo.get(Task, task_id)
      assert Repo.get(Issue, dropped_id) == nil
      assert Repo.get_by(Issue, external_id: "lin_archived_new") == nil
    end

    test "a trashed node is never written, and with a task it is removed with it", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page,
      lookups: lookups
    } do
      %Issue{id: trashed_id} = trashed = insert.("lin_in_trash", :todo)
      {:ok, %Task{id: task_id}} = Pipeline.create_task(trashed, :plan)
      started_at = DateTime.to_iso8601(DateTime.utc_now())

      trashed_node = fn external_id ->
        %{
          "id" => external_id,
          "identifier" => external_id,
          "title" => "Renamed in the trash",
          "archivedAt" => "2026-10-06T09:00:00.000Z",
          "trashed" => true
        }
      end

      last_page.([trashed_node.("lin_in_trash"), trashed_node.("lin_trashed_new")])
      lookups.(%{"lin_in_trash" => %{"data" => %{"issue" => trashed_node.("lin_in_trash")}}})

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert Repo.get(Issue, trashed_id) == nil
      assert Repo.get(Task, task_id) == nil
      assert Repo.get_by(Issue, external_id: "lin_trashed_new") == nil
    end

    test "keeps another project's issue, one written since the start, and one changed while Linear was asked", %{
      project: %{id: project_id, clone_path: clone_path} = project,
      insert: insert,
      last_page: last_page,
      lookups: lookups,
      not_found: not_found
    } do
      {:ok, %Project{id: other_project_id}} =
        Projects.create_project(system_scope(), %{
          name: "Other Sync Project",
          github_repo: "org/other-sync",
          github_installation_id: 12_953,
          key: "OSY",
          default_branch: "main",
          clone_path: "/tmp/repos/other-sync"
        })

      %Issue{id: other_id} =
        %Issue{}
        |> Issue.tracker_changeset(%{
          project_id: other_project_id,
          external_id: "lin_other_project",
          identifier: "OSY-1",
          title: "Someone else's",
          state: :todo
        })
        |> Repo.insert!()

      %Issue{id: webhooked_id} = webhooked = insert.("lin_webhooked", :todo)
      {:ok, %Task{id: webhooked_task_id} = webhooked_task} = Pipeline.create_task(webhooked, :plan)
      worktree_path = Path.join(System.tmp_dir!(), "rail_spared_wt_#{System.unique_integer([:positive])}")
      git!(clone_path, ["worktree", "add", "-b", "spared-branch", worktree_path])

      {:ok, _task} =
        Pipeline.update_task(webhooked_task, %{worktree_name: "spared-branch", worktree_path: worktree_path})

      %Issue{id: claimed_id} = claimed = insert.("lin_claimed", :todo)
      started_at = DateTime.to_iso8601(DateTime.utc_now())
      %Issue{id: fresh_id} = insert.("lin_fresh", :triage)
      {:ok, workspace} = Projects.get_linear_workspace(id: project.linear_workspace_id)

      last_page.([])

      # While Linear is asked about one issue, a webhook rewrites it and a task starts on the other.
      lookups.(%{
        "lin_webhooked" => fn ->
          {:ok, %Issue{}} =
            Issues.handle_linear_webhook(workspace, %{
              "type" => "Issue",
              "action" => "update",
              "data" => %{
                "id" => "lin_webhooked",
                "teamId" => "lin_team_sync",
                "identifier" => "lin_webhooked",
                "title" => "Rewritten meanwhile"
              }
            })

          {:ok, _task} = Pipeline.create_task(claimed, :plan)
          not_found
        end
      })

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert %Issue{id: ^other_id} = Repo.get(Issue, other_id)
      assert %Issue{id: ^fresh_id} = Repo.get(Issue, fresh_id)
      assert %Issue{id: ^webhooked_id, title: "Rewritten meanwhile"} = Repo.get(Issue, webhooked_id)
      assert %Task{id: ^webhooked_task_id} = Repo.get(Task, webhooked_task_id)
      assert File.dir?(worktree_path)
      assert %Issue{id: ^claimed_id} = Repo.get(Issue, claimed_id)
    end

    test "a sync whose only page is empty, or a job with no start time, removes nothing", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page
    } do
      %Issue{id: issue_id} = insert.("lin_unlisted_kept", :todo)
      started_at = DateTime.to_iso8601(DateTime.utc_now())
      Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

      last_page.([])
      assert :ok = perform_job(LinearSync, %{project_id: project_id, started_at: started_at})
      assert_receive {:issues_synced, ^project_id}

      last_page.([])
      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last"})
      assert_receive {:issues_synced, ^project_id}

      assert %Issue{id: ^issue_id} = Repo.get(Issue, issue_id)
    end

    test "a done issue Linear still lists unarchived stays, under Show finished", %{
      project: %{id: project_id},
      insert: insert,
      last_page: last_page
    } do
      %Issue{id: done_id} = insert.("lin_done", :done)
      started_at = DateTime.to_iso8601(DateTime.utc_now())

      last_page.([
        %{
          "id" => "lin_done",
          "identifier" => "lin_done",
          "title" => "Shipped",
          "state" => %{"id" => "st_done", "name" => "Done", "type" => "completed"},
          "archivedAt" => nil,
          "trashed" => false
        }
      ])

      assert :ok = perform_job(LinearSync, %{project_id: project_id, cursor: "cursor_last", started_at: started_at})

      assert %{issues: [%Issue{id: ^done_id, state: :done}]} =
               Issues.list_issues(project_id: project_id, show_finished: true)
    end
  end

  test "a project that is gone needs no sync" do
    # No Linear stub is queued, so a request would raise.
    assert :ok = perform_job(LinearSync, %{project_id: "prj_missing"})
  end
end
