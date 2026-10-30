defmodule Rail.Users.Actions.SetIssuesFiltersTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    [user, teammate] =
      for name <- ["sif_one", "sif_two"] do
        {:ok, user} = Users.register_oauth_user(%{github_id: name, login: name, email: "#{name}@example.com"})
        user
      end

    %{user: user, teammate: teammate}
  end

  test "replaces the scope's user's filters, returning them as saved, and leaves a teammate's alone", %{
    user: user,
    teammate: teammate
  } do
    {:ok, _teammate} = Users.set_issues_filters(Scope.for_user(teammate), %{"mine" => "true"})

    assert {:ok, %User{issues_filters: %{"priority" => "high", "finished" => "true"}}} =
             Users.set_issues_filters(Scope.for_user(user), %{"priority" => "high", "finished" => "true"})

    assert {:ok, %User{issues_filters: %{"cycle" => "current"} = replaced}} =
             Users.set_issues_filters(Scope.for_user(user), %{"cycle" => "current"})

    assert map_size(replaced) == 1
    assert %User{issues_filters: %{"cycle" => "current"}} = Repo.reload!(user)
    assert %User{issues_filters: %{"mine" => "true"}} = Repo.reload!(teammate)
  end

  test "an empty set clears them", %{user: user} do
    {:ok, _saved} = Users.set_issues_filters(Scope.for_user(user), %{"mine" => "true"})
    empty = %{}
    assert {:ok, %User{issues_filters: ^empty}} = Users.set_issues_filters(Scope.for_user(user), %{})
  end

  test "needs a signed-in user" do
    assert {:error, :not_authenticated} = Users.set_issues_filters(Scope.for_system(), %{})
  end
end
