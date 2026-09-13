defmodule Rail.Issues.Actions.CreateIssueTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  test "create_issue/3 creates the ticket as the caller's own Linear identity" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6101",
        github_repo: "org/create-issue-6101",
        github_installation_id: 6101,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_1",
        linear_team_key: "CI1",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6101",
        linear_state_ids: %{"triage" => "st_triage_1"}
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_create_6102",
        login: "create_user_6102",
        email: "create_user_6102@example.com"
      })

    Users.update_user(Scope.for_system(), user, %{
      linear_access_token: "lin_usr_token_valid",
      linear_refresh_token: "lin_refresh_6102",
      linear_token_expires_at: DateTime.shift(DateTime.utc_now(), hour: 1)
    })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_1",
      "identifier" => "ENG-301",
      "title" => "Short ask title",
      "description" => "Short ask title\nMore details here",
      "state" => %{"id" => "st_triage_1", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-301-branch",
      "url" => "https://linear.app/issue/ENG-301",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              id: "iss_" <> _id,
              external_id: "lin_captured_1",
              identifier: "ENG-301",
              title: "Short ask title",
              state: :triage,
              state_name: "Triage"
            }} = Issues.create_issue(project, %{description: "Short ask title\nMore details here"})
  end

  test "create_issue/3 returns error when Linear creation fails" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6105",
        github_repo: "org/create-issue-6105",
        github_installation_id: 6105,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_2",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_capture_6105",
        linear_team_key: "CI5",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6105"
      })

    LinearMock.mock_mutation_failure("issueCreate")

    assert {:error, {:linear_mutation_failed, "issueCreate"}} =
             Issues.create_issue(project, %{description: "Failing ask"})
  end

  test "create_issue/3 creates issue with specified atom priority" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6107",
        github_repo: "org/create-issue-6107",
        github_installation_id: 6107,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_3",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_pri",
        linear_team_key: "CI7",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6107",
        linear_state_ids: %{"triage" => "st_triage_pri"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_1",
      "identifier" => "ENG-303",
      "title" => "Urgent fix",
      "description" => "Urgent fix needed immediately",
      "state" => %{"id" => "st_triage_pri", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-303",
      "url" => "https://linear.app/issue/ENG-303",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              external_id: "lin_captured_pri_1",
              priority: :urgent
            }} = Issues.create_issue(project, %{description: "Urgent fix needed immediately", priority: :urgent})
  end

  test "create_issue/3 casts a string priority" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6108",
        github_repo: "org/create-issue-6108",
        github_installation_id: 6108,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_4",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_str",
        linear_team_key: "CI8",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6108",
        linear_state_ids: %{"triage" => "st_triage_str"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_2",
      "identifier" => "ENG-304",
      "title" => "Low task",
      "description" => "Low task details",
      "state" => %{"id" => "st_triage_str", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-304",
      "url" => "https://linear.app/issue/ENG-304",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              external_id: "lin_captured_pri_2",
              priority: :low
            }} = Issues.create_issue(project, %{description: "Low task details", priority: "low"})
  end

  test "create_issue/3 refuses a priority that is not one of the known ones" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6109",
        github_repo: "org/create-issue-6109",
        github_installation_id: 6109,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_5",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_inv",
        linear_team_key: "CI9",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6109",
        linear_state_ids: %{"triage" => "st_triage_inv"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_3",
      "identifier" => "ENG-305",
      "title" => "Invalid prio task",
      "description" => "Some description",
      "state" => %{"id" => "st_triage_inv", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-305",
      "url" => "https://linear.app/issue/ENG-305",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:error, %Ecto.Changeset{} = changeset} =
             Issues.create_issue(project, %{description: "Some description", priority: "invalid_priority"})

    assert %{priority: ["is invalid"]} = errors_on(changeset)
  end

  test "create_issue/3 falls back to medium on nil priority" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6110",
        github_repo: "org/create-issue-6110",
        github_installation_id: 6110,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_6",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_nil",
        linear_team_key: "CI10",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6110",
        linear_state_ids: %{"triage" => "st_triage_nil"}
      })

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_captured_pri_4",
      "identifier" => "ENG-306",
      "title" => "Nil prio task",
      "description" => "Nil priority description",
      "state" => %{"id" => "st_triage_nil", "name" => "Triage", "type" => "triage"},
      "branchName" => "eng-306",
      "url" => "https://linear.app/issue/ENG-306",
      "createdAt" => "2026-09-02T10:00:00.000Z",
      "updatedAt" => "2026-09-02T10:00:00.000Z"
    })

    assert {:ok,
            %Issue{
              external_id: "lin_captured_pri_4",
              priority: :medium
            }} = Issues.create_issue(project, %{description: "Nil priority description", priority: nil})
  end

  test "create_issue/3 titles the ticket with the first line of the description" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6111",
        github_repo: "org/create-issue-6111",
        github_installation_id: 6111,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_7",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_title",
        linear_team_key: "CI11",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6111",
        linear_state_ids: %{"triage" => "st_triage_title"}
      })

    # Linear is what names the issue, so the derived title is only visible in the
    # mutation: echo it back as the created ticket to see what was sent.
    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"variables" => %{"input" => %{"title" => title}}} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_title_1", "identifier" => "ENG-307", "title" => title}
            }
          }
        })
      )
    end)

    assert {:ok, %Issue{title: "Second line is the title"}} =
             Issues.create_issue(project, %{description: "\n  \nSecond line is the title\nand a body"})
  end

  test "create_issue/3 trims a long first line at a word boundary" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6112",
        github_repo: "org/create-issue-6112",
        github_installation_id: 6112,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_8",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_long",
        linear_team_key: "CI12",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6112",
        linear_state_ids: %{"triage" => "st_triage_long"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"variables" => %{"input" => %{"title" => title}}} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_title_2", "identifier" => "ENG-308", "title" => title}
            }
          }
        })
      )
    end)

    ask = String.duplicate("word ", 40)

    assert {:ok, %Issue{title: title}} = Issues.create_issue(project, %{description: ask})
    assert String.length(title) <= 91
    assert String.ends_with?(title, "word…")
  end

  test "create_issue/3 cuts an unbroken first line mid-word" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6113",
        github_repo: "org/create-issue-6113",
        github_installation_id: 6113,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_9",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_unbroken",
        linear_team_key: "CI13",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6113",
        linear_state_ids: %{"triage" => "st_triage_unbroken"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"variables" => %{"input" => %{"title" => title}}} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_title_3", "identifier" => "ENG-309", "title" => title}
            }
          }
        })
      )
    end)

    ask = String.duplicate("a", 200)

    expected = String.duplicate("a", 90) <> "…"

    assert {:ok, %Issue{title: ^expected}} = Issues.create_issue(project, %{description: ask})
  end

  test "create_issue/3 keeps a title the caller gave and tolerates a missing description" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6114",
        github_repo: "org/create-issue-6114",
        github_installation_id: 6114,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_10",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_given",
        linear_team_key: "CI14",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6114",
        linear_state_ids: %{"triage" => "st_triage_given"}
      })

    Req.Test.expect(Rail.Linear, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"variables" => %{"input" => %{"title" => title}}} = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => %{"id" => "lin_title_4", "identifier" => "ENG-310", "title" => title}
            }
          }
        })
      )
    end)

    assert {:ok, %Issue{title: "An explicit title"}} =
             Issues.create_issue(project, %{title: "An explicit title"})
  end

  test "create_issue/3 refuses a description with no line to title it with" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6115",
        github_repo: "org/create-issue-6115",
        github_installation_id: 6115,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_11",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_empty",
        linear_team_key: "CI15",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6115",
        linear_state_ids: %{"triage" => "st_triage_empty"}
      })

    LinearMock.mock_create_issue_success(%{"id" => "lin_title_5", "identifier" => "ENG-311", "title" => ""})

    assert {:error, %Ecto.Changeset{} = changeset} =
             Issues.create_issue(project, %{description: "   "})

    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end

  test "create_issue/3 refuses attrs carrying neither a title nor a description" do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "Create Issue Project 6116",
        github_repo: "org/create-issue-6116",
        github_installation_id: 6116,
        linear_workspace: %{
          name: "Create Issue Workspace",
          external_id: "lin_ws_create_issue_12",
          token: "lin_api_token_create_issue",
          webhook_secret: "whsec_create_issue"
        },
        linear_team_id: "team_cap_none",
        linear_team_key: "CI16",
        default_branch: "main",
        clone_path: "/tmp/repos/create-issue-6116",
        linear_state_ids: %{"triage" => "st_triage_none"}
      })

    LinearMock.mock_create_issue_success(%{"id" => "lin_title_6", "identifier" => "ENG-312", "title" => nil})

    assert {:error, %Ecto.Changeset{} = changeset} = Issues.create_issue(project, %{})

    assert %{title: ["can't be blank"]} = errors_on(changeset)
  end
end
