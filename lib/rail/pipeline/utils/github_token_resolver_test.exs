defmodule Rail.Pipeline.Utils.GitHubTokenResolverTest do
  use Rail.DataCase, async: true

  import Rail.Pipeline.Utils.GitHubTokenResolver
  import RailTest.Mocks.GitHub

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  test "resolves explicit token from opts" do
    project = Repo.insert!(Project.factory())

    assert {:ok, "custom_tok"} = resolve_github_token(nil, project, token: "custom_tok")
    assert {:ok, "custom_tok_2"} = resolve_github_token(nil, project, github_token: "custom_tok_2")
  end

  test "resolves user token from User struct and Scope" do
    user = Repo.insert!(%{User.factory() | github_token: "gho_user_tok_1"})
    project = Repo.insert!(Project.factory())
    scope = Scope.for_user(user)

    assert {:ok, "gho_user_tok_1"} = resolve_github_token(user, project)
    assert {:ok, "gho_user_tok_1"} = resolve_github_token(scope, project)
  end

  test "resolves user token from user id string" do
    user = Repo.insert!(%{User.factory() | github_token: "gho_user_tok_2"})
    project = Repo.insert!(Project.factory())

    assert {:ok, "gho_user_tok_2"} = resolve_github_token(user.id, project)
  end

  test "falls back to installation token when user has no github token" do
    mock_installation_token_success(installation_id: 88_888, token: "ghs_inst_tok_888")

    project = Repo.insert!(%{Project.factory() | github_installation_id: 88_888})
    user = Repo.insert!(%{User.factory() | github_token: nil})
    scope = Scope.for_user(user)

    assert {:ok, "ghs_inst_tok_888"} = resolve_github_token(scope, project)
  end

  test "falls back to installation token when user id not found" do
    mock_installation_token_success(installation_id: 77_777, token: "ghs_inst_tok_777")

    project = Repo.insert!(%{Project.factory() | github_installation_id: 77_777})

    assert {:ok, "ghs_inst_tok_777"} = resolve_github_token("usr_nonexistent", project)
  end

  test "returns error when no user token and project has no installation id" do
    project = %Project{github_installation_id: nil}

    assert {:error, :missing_github_token} = resolve_github_token(nil, project)
    assert {:error, :missing_github_token} = resolve_github_token(nil, nil)
  end
end
