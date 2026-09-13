defmodule Rail.Pipeline.Utils.GitHubTokenResolverTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.GitHubTokenResolver
  import RailTest.Mocks.GitHub

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Roles
  alias Rail.Scope
  alias Rail.Users
  alias RailTest.Mocks.Linear, as: LinearMock

  setup do
    {:ok, backend} =
      Rail.Backends.create_backend(system_scope(), %{name: :claude, executable_path: "/usr/bin/true"})

    scope = system_scope()

    {:ok, workspace} =
      Projects.upsert_linear_workspace(system_scope(), %{
        name: "GH Token Workspace",
        external_id: "lin_ws_gh_token",
        token: "lin_api_token_gh_token",
        webhook_secret: "whsec_gh_token"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "GH Token Project 9901",
        github_repo: "org/gh-token-9901",
        github_installation_id: 9901,
        linear_workspace_id: workspace.id,
        linear_team_id: "team_gh_token_9901",
        linear_team_key: "P9901",
        default_branch: "main",
        clone_path: "/tmp/repos/gh-token-9901",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    roles =
      Map.new([:product, :design, :architect, :engineer, :review, :qa, :qa_lead, :demo], fn stage ->
        {:ok, role} =
          Roles.create_role(scope, project, %{
            backend_id: backend.id,
            stage: stage,
            name: "#{stage} role",
            model: "claude-3-7-sonnet",
            system_prompt: "You are the #{stage} agent."
          })

        {stage, role}
      end)

    LinearMock.mock_create_issue_success(%{
      "id" => "lin_gh_token_1",
      "identifier" => "GHT-1",
      "title" => "GH Token Issue"
    })

    {:ok, issue} = Issues.create_issue(project, %{description: "GH Token Issue"})

    {:ok, task} = Pipeline.create_task(issue, :product)

    %{project: project, issue: issue, task: task, roles: roles}
  end

  test "resolves explicit token from opts", %{project: _project} do
    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "GH Token Project 9902",
        github_repo: "org/gh-token-9902",
        github_installation_id: 9902,
        linear_team_id: "team_gh_token_9902",
        linear_team_key: "P9902",
        default_branch: "main",
        clone_path: "/tmp/repos/gh-token-9902",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, "custom_tok"} = resolve_github_token(nil, project, token: "custom_tok")
    assert {:ok, "custom_tok_2"} = resolve_github_token(nil, project, github_token: "custom_tok_2")
  end

  test "resolves user token from user id string", %{project: _project} do
    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_gh_token_9905",
        login: "gh_token_user_9905",
        email: "gh_token_user_9905@example.com",
        github_token: "gho_user_tok_2"
      })

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "GH Token Project 9906",
        github_repo: "org/gh-token-9906",
        github_installation_id: 9906,
        linear_team_id: "team_gh_token_9906",
        linear_team_key: "P9906",
        default_branch: "main",
        clone_path: "/tmp/repos/gh-token-9906",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, "gho_user_tok_2"} = resolve_github_token(user.id, project)
  end

  test "falls back to installation token when user has no github token", %{project: _project} do
    mock_installation_token_success(installation_id: 88_888, token: "ghs_inst_tok_888")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "GH Token Project 9907",
        github_repo: "org/gh-token-9907",
        github_installation_id: 88_888,
        linear_team_id: "team_gh_token_9907",
        linear_team_key: "P9907",
        default_branch: "main",
        clone_path: "/tmp/repos/gh-token-9907",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    {:ok, user} =
      Users.register_oauth_user(%{
        github_id: "gh_gh_token_9908",
        login: "gh_token_user_9908",
        email: "gh_token_user_9908@example.com",
        github_token: nil
      })

    scope = Scope.for_user(user)

    assert {:ok, "ghs_inst_tok_888"} = resolve_github_token(scope, project)
  end

  test "falls back to installation token when user id not found", %{project: _project} do
    mock_installation_token_success(installation_id: 77_777, token: "ghs_inst_tok_777")

    {:ok, project} =
      Projects.create_project(system_scope(), %{
        name: "GH Token Project 9909",
        github_repo: "org/gh-token-9909",
        github_installation_id: 77_777,
        linear_team_id: "team_gh_token_9909",
        linear_team_key: "P9909",
        default_branch: "main",
        clone_path: "/tmp/repos/gh-token-9909",
        linear_state_ids: %{
          "triage" => "st_triage",
          "backlog" => "st_backlog",
          "in_progress" => "st_in_progress",
          "done" => "st_done",
          "canceled" => "st_canceled"
        }
      })

    assert {:ok, "ghs_inst_tok_777"} = resolve_github_token("usr_nonexistent", project)
  end

  test "returns error when no user token and project has no installation id", %{project: _project} do
    project = %Project{github_installation_id: nil}

    assert {:error, :missing_github_token} = resolve_github_token(nil, project)
    assert {:error, :missing_github_token} = resolve_github_token(nil, nil)
  end
end
