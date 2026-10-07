defmodule Rail.Projects.Actions.UpdateProjectTest do
  use Rail.DataCase, async: true

  alias Rail.Issues.Schemas.Issue
  alias Rail.Projects
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Scope

  test "admin updates project successfully" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{id: project_id} = project} =
             Projects.create_project(admin_scope, %{
               name: "Original Name",
               github_repo: repo,
               github_installation_id: 55_667,
               linear_team_key: "ORIG",
               default_branch: "main",
               clone_path: "/tmp/orig"
             })

    assert {:ok, %Project{id: ^project_id, name: "Updated Name", active: false, default_branch: "develop"}} =
             Projects.update_project(admin_scope, project, %{
               name: "Updated Name",
               active: false,
               default_branch: "develop"
             })
  end

  test "a project's tracker and key are fixed once it has issues", %{github_project: github_project} do
    admin_scope = Scope.for_user(%{admin: true})

    assert {:ok, %Project{tracker: :linear} = project} =
             Projects.create_project(admin_scope, %{
               name: "Tracked",
               github_repo: "example/tracked-#{System.unique_integer([:positive])}",
               github_installation_id: 55_669,
               linear_team_key: "TRK",
               default_branch: "main",
               clone_path: "/tmp/tracked"
             })

    assert {:ok, %Project{tracker: :github, key: "trk"} = project} =
             Projects.update_project(admin_scope, project, %{tracker: "github", key: "trk"})

    %Issue{}
    |> Issue.changeset(%{
      project_id: project.id,
      external_id: "I_trk1",
      identifier: "trk#1",
      title: "One",
      state: :backlog
    })
    |> Repo.insert!()

    assert {:error, changeset} = Projects.update_project(admin_scope, project, %{tracker: "linear"})
    assert %{tracker: ["cannot change once the project has issues"]} = errors_on(changeset)

    assert {:error, changeset} = Projects.update_project(admin_scope, project, %{key: "other"})
    assert %{tracker: ["cannot change once the project has issues"]} = errors_on(changeset)

    assert {:ok, %Project{name: "Renamed"}} = Projects.update_project(admin_scope, project, %{name: "Renamed"})

    assert {:error, changeset} =
             Projects.create_project(admin_scope, %{
               name: "Same Key",
               github_repo: "example/same-key-#{System.unique_integer([:positive])}",
               github_installation_id: 55_670,
               tracker: "github",
               key: github_project.key,
               default_branch: "main",
               clone_path: "/tmp/same-key"
             })

    assert %{key: ["has already been taken"]} = errors_on(changeset)
  end

  test "moving a project to another workspace looks its team up through that one" do
    admin_scope = Scope.for_user(%{admin: true})

    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_old"]
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_old"}]}}})
    end)

    workspace = fn key ->
      {:ok, workspace} =
        Projects.create_linear_workspace(admin_scope, %{
          name: key,
          external_id: "lin_org_#{key}",
          token: "lin_api_#{key}",
          webhook_secret: "wh"
        })

      workspace
    end

    %LinearWorkspace{id: old_id} = workspace.("old")
    %LinearWorkspace{id: new_id} = workspace.("new")

    assert {:ok, %Project{linear_team_id: "lin_team_old"} = project} =
             Projects.create_project(admin_scope, %{
               name: "Moving Project",
               github_repo: "example/moving-#{System.unique_integer([:positive])}",
               github_installation_id: 55_668,
               linear_team_key: "MOV",
               default_branch: "main",
               clone_path: "/tmp/move",
               linear_workspace_id: old_id
             })

    Req.Test.expect(Rail.Linear, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer lin_api_new"]
      Req.Test.json(conn, %{"data" => %{"teams" => %{"nodes" => [%{"id" => "lin_team_new"}]}}})
    end)

    assert {:ok, %Project{linear_team_id: "lin_team_new", linear_workspace: %LinearWorkspace{id: ^new_id}}} =
             Projects.update_project(admin_scope, project, %{linear_workspace_id: new_id})
  end

  test "returns validation error changeset for invalid attributes" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/invalid-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Valid Project",
               github_repo: repo,
               github_installation_id: 55_669,
               linear_team_key: "INV",
               default_branch: "main",
               clone_path: "/tmp/inv"
             })

    assert {:error, changeset} = Projects.update_project(admin_scope, project, %{name: ""})
    assert %{name: ["can't be blank"]} = errors_on(changeset)
  end

  test "rejects non-admin user scope" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/unauth-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Project to Guard",
               github_repo: repo,
               github_installation_id: 55_670,
               linear_team_key: "GRD",
               default_branch: "main",
               clone_path: "/tmp/guard"
             })

    user_scope = Scope.for_user(%{admin: false})
    assert {:error, :not_authorized} = Projects.update_project(user_scope, project, %{name: "Hacked"})
  end

  test "rejects nil scope" do
    admin_scope = Scope.for_user(%{admin: true})
    repo = "example/nil-update-repo-#{System.unique_integer([:positive])}"

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Project to Guard Nil",
               github_repo: repo,
               github_installation_id: 55_671,
               linear_team_key: "GRDN",
               default_branch: "main",
               clone_path: "/tmp/guard_nil"
             })

    assert {:error, :not_authorized} = Projects.update_project(nil, project, %{name: "Hacked"})
  end

  test "a worktree setup script has to be a path inside the repository" do
    admin_scope = Scope.for_user(%{admin: true})

    assert {:ok, %Project{} = project} =
             Projects.create_project(admin_scope, %{
               name: "Setup Project",
               github_repo: "example/setup-repo-#{System.unique_integer([:positive])}",
               github_installation_id: 55_670,
               linear_team_key: "SET",
               default_branch: "main",
               clone_path: "/tmp/set"
             })

    assert {:ok, %Project{worktree_setup_script: "scripts/setup-worktree.sh"}} =
             Projects.update_project(admin_scope, project, %{worktree_setup_script: "scripts/setup-worktree.sh"})

    for outside <- ["/usr/local/bin/setup", "../elsewhere/setup.sh"] do
      assert {:error, changeset} = Projects.update_project(admin_scope, project, %{worktree_setup_script: outside})
      assert %{worktree_setup_script: ["must be a path inside the repository"]} = errors_on(changeset)
    end
  end

  test "names the user whose MCP connections triage uses", %{project: project} do
    unique = System.unique_integer([:positive])

    {:ok, %{id: user_id}} =
      Rail.Users.register_oauth_user(%{github_id: "tri_#{unique}", login: "tri_#{unique}", email: "tri_#{unique}@x.com"})

    assert {:ok, %Project{triage_user_id: ^user_id}} =
             Projects.update_project(system_scope(), project, %{"triage_user_id" => user_id})
  end

  describe "slack channels" do
    setup do
      unique = System.unique_integer([:positive])
      Req.Test.expect(Rail.Slack, &Req.Test.json(&1, %{"ok" => true, "team_id" => "T#{unique}"}))
      {:ok, workspace} = Projects.create_slack_workspace(system_scope(), %{"name" => "Acme", "token" => "xoxb-1"})

      %{
        workspace: workspace,
        feedback: %{"external_id" => "C#{unique}a", "name" => "rail-feedback", "slack_workspace_id" => workspace.id},
        posthog: %{"external_id" => "C#{unique}b", "name" => "posthog-index", "slack_workspace_id" => workspace.id}
      }
    end

    test "sets each channel as Slack listed it, with its bot switch, and replaces the previous set", %{
      project: project,
      workspace: %{id: workspace_id},
      feedback: %{"external_id" => feedback_id} = feedback,
      posthog: %{"external_id" => posthog_id} = posthog
    } do
      assert {:ok,
              %Project{
                slack_channels: [
                  %SlackChannel{external_id: ^feedback_id, name: "rail-feedback", slack_workspace_id: ^workspace_id}
                ]
              }} = Projects.update_project(system_scope(), project, %{"slack_channels" => [feedback]})

      assert {:ok, %Project{slack_channels: [%SlackChannel{external_id: ^posthog_id, bot_triage_enabled: true}]}} =
               Projects.update_project(system_scope(), project, %{
                 "slack_channels" => [Map.put(posthog, "bot_triage_enabled", "true")]
               })

      assert [%SlackChannel{external_id: ^posthog_id}] = Projects.list_slack_channels(project)
    end

    test "updates a channel it already has in place, so its threads stay, and leaves channels alone when not sent", %{
      project: project,
      workspace: workspace,
      feedback: feedback,
      posthog: %{"external_id" => posthog_id} = posthog
    } do
      {:ok, %Project{slack_channels: [%SlackChannel{id: channel_id} = channel]} = project} =
        Projects.update_project(system_scope(), project, %{"slack_channels" => [feedback]})

      {:ok, %{id: thread_id}} =
        Rail.Triage.handle_slack_event(
          workspace,
          slack_message_event(channel, %{"bot_id" => "B_PH", "username" => "PostHog", "text" => "TypeError"})
        )

      kept = Map.merge(feedback, %{"id" => channel_id, "name" => "renamed", "bot_triage_enabled" => "true"})

      assert {:ok,
              %Project{
                slack_channels: [
                  %SlackChannel{id: ^channel_id, name: "renamed", bot_triage_enabled: true},
                  %SlackChannel{external_id: ^posthog_id}
                ]
              } = project} = Projects.update_project(system_scope(), project, %{"slack_channels" => [kept, posthog]})

      assert {:ok, %{id: ^thread_id}} = Rail.Triage.get_triage_thread(system_scope(), thread_id)

      assert {:ok, %Project{name: "Renamed project"}} =
               Projects.update_project(system_scope(), project, %{"name" => "Renamed project"})

      assert [%SlackChannel{external_id: ^posthog_id}, %SlackChannel{id: ^channel_id}] =
               Projects.list_slack_channels(project)
    end

    test "sets the learnings channel, returns its workspace, and announces the project on projects", %{
      project: %{id: project_id} = project,
      workspace: %{id: workspace_id}
    } do
      Phoenix.PubSub.subscribe(Rail.PubSub, "projects")

      assert {:ok,
              %Project{
                learnings_slack_workspace: %SlackWorkspace{id: ^workspace_id, name: "Acme"},
                learnings_channel_external_id: "C_LEARN"
              } = updated} =
               Projects.update_project(system_scope(), project, %{
                 "learnings_slack_workspace_id" => workspace_id,
                 "learnings_channel_external_id" => "C_LEARN"
               })

      assert_received {:project_changed, ^project_id}

      assert {:ok, %Project{learnings_slack_workspace_id: nil, learnings_channel_external_id: nil}} =
               Projects.update_project(system_scope(), updated, %{
                 "learnings_slack_workspace_id" => "",
                 "learnings_channel_external_id" => ""
               })
    end

    test "a learnings channel needs the workspace that posts there", %{project: project} do
      assert {:error, changeset} =
               Projects.update_project(system_scope(), project, %{"learnings_channel_external_id" => "C_LEARN"})

      assert %{learnings_slack_workspace_id: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Projects.update_project(system_scope(), project, %{
                 "learnings_slack_workspace_id" => "sw_missing",
                 "learnings_channel_external_id" => "C_LEARN"
               })

      assert %{learnings_slack_workspace_id: ["does not exist"]} = errors_on(changeset)
    end

    test "one project's learnings channel leaves another's alone", %{project: project, workspace: workspace} do
      {:ok, %Project{id: other_id}} =
        Projects.create_project(system_scope(), %{
          name: "Other",
          github_repo: "example/other-#{System.unique_integer([:positive])}",
          github_installation_id: 2,
          linear_team_key: "OTH",
          default_branch: "main",
          clone_path: "/tmp/other"
        })

      {:ok, other} = Projects.get_project(other_id)

      {:ok, _other} =
        Projects.update_project(system_scope(), other, %{
          "learnings_slack_workspace_id" => workspace.id,
          "learnings_channel_external_id" => "C_OTHER"
        })

      {:ok, _project} =
        Projects.update_project(system_scope(), project, %{
          "learnings_slack_workspace_id" => workspace.id,
          "learnings_channel_external_id" => "C_MINE"
        })

      assert {:ok, %Project{learnings_channel_external_id: "C_OTHER"}} = Projects.get_project(other_id)
    end

    test "saving triage channels without the learnings channel keeps it", %{
      project: project,
      workspace: %{id: workspace_id},
      feedback: %{"external_id" => feedback_id} = feedback,
      posthog: posthog
    } do
      {:ok, project} = Projects.update_project(system_scope(), project, %{"slack_channels" => [feedback]})

      {:ok, project} =
        Projects.update_project(system_scope(), project, %{
          "learnings_slack_workspace_id" => workspace_id,
          "learnings_channel_external_id" => feedback_id
        })

      assert {:ok,
              %Project{
                slack_channels: [%SlackChannel{name: "posthog-index"}],
                learnings_slack_workspace_id: ^workspace_id,
                learnings_channel_external_id: ^feedback_id
              }} = Projects.update_project(system_scope(), project, %{"slack_channels" => [posthog]})
    end

    test "marks a channel external, leaves the others and any sent without the switch unmarked, and unmarks it", %{
      project: %{id: project_id} = project,
      feedback: %{"external_id" => feedback_id} = feedback,
      posthog: %{"external_id" => posthog_id} = posthog
    } do
      Phoenix.PubSub.subscribe(Rail.PubSub, "projects")

      assert {:ok,
              %Project{
                slack_channels: [
                  %SlackChannel{external_id: ^feedback_id, external: true},
                  %SlackChannel{external_id: ^posthog_id, external: false}
                ]
              } = project} =
               Projects.update_project(system_scope(), project, %{
                 "slack_channels" => [Map.put(feedback, "external", "true"), posthog]
               })

      assert_received {:project_changed, ^project_id}

      assert [%SlackChannel{external_id: ^posthog_id, external: false}, %SlackChannel{external: true} = channel] =
               Projects.list_slack_channels(project)

      # The describe's one Slack answer is spent, so unmarking that reached Slack would crash.
      unmarked = Map.merge(feedback, %{"id" => channel.id, "external" => "false"})

      assert {:ok, %Project{slack_channels: [%SlackChannel{external_id: ^feedback_id, external: false}]}} =
               Projects.update_project(system_scope(), project, %{"slack_channels" => [unmarked]})

      assert_received {:project_changed, ^project_id}
    end

    test "refuses a channel another project holds, or a workspace Rail does not have", %{
      project: project,
      feedback: feedback
    } do
      {:ok, other} =
        Projects.create_project(system_scope(), %{
          name: "Other",
          github_repo: "example/other-#{System.unique_integer([:positive])}",
          github_installation_id: 2,
          linear_team_key: "OTH",
          default_branch: "main",
          clone_path: "/tmp/other"
        })

      assert {:ok, _held} = Projects.update_project(system_scope(), other, %{"slack_channels" => [feedback]})

      assert {:error, changeset} = Projects.update_project(system_scope(), project, %{"slack_channels" => [feedback]})
      assert %{slack_channels: [%{external_id: ["is connected to another project"]}]} = errors_on(changeset)
      assert [] = Projects.list_slack_channels(project)

      elsewhere = %{"external_id" => "C_ELSEWHERE", "name" => "x", "slack_workspace_id" => "sw_missing"}
      assert {:error, changeset} = Projects.update_project(system_scope(), project, %{"slack_channels" => [elsewhere]})
      assert %{slack_channels: [%{slack_workspace_id: ["does not exist"]}]} = errors_on(changeset)
    end
  end
end
