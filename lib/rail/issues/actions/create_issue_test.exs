defmodule Rail.Issues.Actions.CreateIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Users

  test "create_issue/2 opens the ticket in triage with the title and description given", %{
    project: %{id: project_id} = project
  } do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "input" => %{
                 "teamId" => "lin_team_id",
                 "title" => "Short title",
                 "description" => "More details here",
                 "stateId" => "st_triage",
                 "priority" => 2
               }
             } = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{
              "id" => "lin_captured_1",
              "identifier" => "ENG-301",
              "title" => "Short title",
              "description" => "More details here",
              "priority" => 2,
              "state" => %{"id" => "st_triage", "name" => "Triage", "type" => "triage"},
              "branchName" => "eng-301-branch",
              "url" => "https://linear.app/issue/ENG-301"
            }
          }
        }
      })
    end)

    Phoenix.PubSub.subscribe(Rail.PubSub, "issues")

    assert {:ok,
            %Issue{
              id: "iss_" <> _id = issue_id,
              project_id: ^project_id,
              external_id: "lin_captured_1",
              identifier: "ENG-301",
              title: "Short title",
              description: "More details here",
              priority: :high,
              state: :triage,
              state_name: "Triage",
              branch_name: "eng-301-branch",
              url: "https://linear.app/issue/ENG-301"
            }} =
             Issues.create_issue(system_scope(), project, %{
               title: "Short title",
               description: "More details here",
               priority: :high
             })

    assert_receive {:issue_created, ^issue_id}
  end

  test "create_issue/2 opens a sub-issue in Todo under its parent, with its estimate and its owner assigned", %{
    project: project
  } do
    {:ok, %{id: owner_id} = owner} =
      Users.register_oauth_user(%{github_id: "gh_sub_issue_owner", login: "sub_owner", email: "sub_owner@example.com"})

    owner |> Ecto.Changeset.change(linear_user_id: "lin_usr_sub_owner") |> Repo.update!()
    parent = %Issue{external_id: "lin_parent_1"}

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert %{
               "input" => %{
                 "title" => "A child",
                 "parentId" => "lin_parent_1",
                 "estimate" => 3,
                 "assigneeId" => "lin_usr_sub_owner",
                 "stateId" => "st_todo"
               }
             } = Jason.decode!(body)["variables"]

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_child_1", "identifier" => "ENG-310", "title" => "A child", "estimate" => 3}
          }
        }
      })
    end)

    assert {:ok, %Issue{state: :todo, state_name: "Todo", estimate: 3, owner_user_id: ^owner_id}} =
             Issues.create_issue(system_scope(), project, %{
               title: "A child",
               estimate: 3,
               owner_user_id: owner.id,
               parent: parent
             })
  end

  test "create_issue/2 leaves an owner who never linked Linear unassigned there", %{project: project} do
    {:ok, owner} =
      Users.register_oauth_user(%{github_id: "gh_unlinked_owner", login: "unlinked", email: "unlinked@example.com"})

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(body)["variables"]["input"], "assigneeId")

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_captured_9", "identifier" => "ENG-309", "title" => "Unlinked"}
          }
        }
      })
    end)

    assert {:ok, %Issue{state: :triage}} =
             Issues.create_issue(system_scope(), project, %{title: "Unlinked", owner_user_id: owner.id})
  end

  test "create_issue/2 defaults to medium priority and sends Linear none", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      input = Jason.decode!(body)["variables"]["input"]

      refute Map.has_key?(input, "priority")
      refute Map.has_key?(input, "description")

      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_captured_2", "identifier" => "ENG-302", "title" => "No priority"}
          }
        }
      })
    end)

    assert {:ok, %Issue{priority: :medium, state: :triage, state_name: "Triage"}} =
             Issues.create_issue(system_scope(), project, %{title: "No priority"})
  end

  test "create_issue/2 refuses a priority that is not one of the known ones", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_captured_3", "identifier" => "ENG-303", "title" => "Bad priority"}
          }
        }
      })
    end)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Issues.create_issue(system_scope(), project, %{title: "Bad priority", priority: "invalid_priority"})

    assert %{priority: ["is invalid"]} = errors_on(changeset)
  end

  test "create_issue/2 returns an error when Linear does not create it", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{"data" => %{"issueCreate" => %{"success" => false}}})
    end)

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Issues.create_issue(system_scope(), project, %{title: "Failing", description: "Failing"})
  end

  test "create_issue/2 opens nothing for a project whose Linear team is not known yet" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "No Team Project",
        github_repo: "org/create-issue-no-team",
        github_installation_id: 6120,
        linear_team_key: "NTP",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-no-team"
      })

    # No Linear stub is queued, so a request would raise.
    assert {:error, :linear_team_not_found} = Issues.create_issue(system_scope(), project, %{title: "Nowhere to go"})
  end

  test "create_issue/2 returns Linear's error", %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "down"})
    end)

    assert {:error, {:linear_api_error, 500, _body}} = Issues.create_issue(system_scope(), project, %{title: "Failing"})
  end
end
