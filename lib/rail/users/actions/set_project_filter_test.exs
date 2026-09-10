defmodule Rail.Users.Actions.SetProjectFilterTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "updates last_project_filter for user struct in scope" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "filter_user_gh",
               login: "filter_user",
               email: "filteruser@example.com"
             })

    scope = Scope.for_user(user)

    assert {:ok, %User{last_project_filter: "prj_01abcdef"}} =
             Users.set_project_filter(scope, "prj_01abcdef")

    assert {:ok, %User{last_project_filter: nil}} =
             Users.set_project_filter(scope, nil)
  end

  test "updates last_project_filter for user map in scope" do
    assert {:ok, user} =
             Users.register_oauth_user(%{
               github_id: "filter_map_gh",
               login: "filter_map",
               email: "filtermap@example.com"
             })

    scope = Scope.for_user(%{id: user.id})

    assert {:ok, %User{last_project_filter: "prj_999"}} =
             Users.set_project_filter(scope, "prj_999")
  end

  test "returns error when scope has no user" do
    assert {:error, :not_authorized} = Users.set_project_filter(Scope.for_system(), "prj_123")
    assert {:error, :not_authorized} = Users.set_project_filter(nil, "prj_123")
  end
end
