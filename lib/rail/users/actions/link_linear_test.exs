defmodule Rail.Users.Actions.LinkLinearTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup do
    id = System.unique_integer([:positive])

    assert {:ok, %User{id: user_id} = user} =
             Users.register_oauth_user(%{
               github_id: "link_gh_#{id}",
               login: "link_user_#{id}",
               email: "link_#{id}@example.com"
             })

    %{user: user, user_id: user_id, scope: Scope.for_user(user)}
  end

  test "links linear with user scope and atom keys", %{scope: scope, user_id: user_id} do
    attrs = %{
      linear_user_id: "lin_usr_atom",
      linear_name: "Atom User",
      linear_access_token: "lin_at_atom",
      linear_refresh_token: "lin_rt_atom",
      expires_in: 3600
    }

    assert {:ok,
            %User{
              id: ^user_id,
              linear_user_id: "lin_usr_atom",
              linear_name: "Atom User",
              linear_access_token: "lin_at_atom",
              linear_refresh_token: "lin_rt_atom",
              linear_token_expires_at: %DateTime{}
            }} = Users.link_linear(scope, attrs)
  end

  test "links linear with map-user scope and string keys", %{user_id: user_id} do
    scope = %Scope{user: %{id: user_id}}

    attrs = %{
      "user_id" => "lin_usr_str",
      "name" => "String User",
      "access_token" => "lin_at_str",
      "refresh_token" => "lin_rt_str",
      "expires_in" => "7200"
    }

    assert {:ok,
            %User{
              id: ^user_id,
              linear_user_id: "lin_usr_str",
              linear_name: "String User",
              linear_access_token: "lin_at_str",
              linear_refresh_token: "lin_rt_str",
              linear_token_expires_at: %DateTime{}
            }} = Users.link_linear(scope, attrs)
  end

  test "links linear with User struct directly and DateTime expires_at", %{
    user: user,
    user_id: user_id
  } do
    expires = DateTime.utc_now()

    attrs = %{
      linear_user_id: "lin_usr_struct",
      linear_name: "Struct User",
      linear_access_token: "lin_at_struct",
      linear_refresh_token: "lin_rt_struct",
      linear_token_expires_at: expires
    }

    assert {:ok,
            %User{
              id: ^user_id,
              linear_user_id: "lin_usr_struct",
              linear_name: "Struct User",
              linear_access_token: "lin_at_struct",
              linear_refresh_token: "lin_rt_struct"
            }} = Users.link_linear(user, attrs)
  end

  test "links linear using user id string directly", %{user_id: user_id} do
    attrs = %{
      access_token: "lin_at_by_id",
      refresh_token: "lin_rt_by_id",
      expires_in: 1800
    }

    assert {:ok,
            %User{
              id: ^user_id,
              linear_access_token: "lin_at_by_id",
              linear_refresh_token: "lin_rt_by_id"
            }} = Users.link_linear(user_id, attrs)
  end

  test "returns not_found when user does not exist" do
    attrs = %{
      linear_access_token: "at",
      linear_refresh_token: "rt",
      expires_in: 3600
    }

    assert {:error, :not_found} = Users.link_linear("usr_nonexistent12345", attrs)
  end

  test "returns not_authorized when scope is invalid" do
    assert {:error, :not_authorized} = Users.link_linear(nil, %{})
    assert {:error, :not_authorized} = Users.link_linear(%Scope{user: nil}, %{})
  end

  test "returns changeset error when required tokens are missing", %{scope: scope} do
    assert {:error, changeset} = Users.link_linear(scope, %{})
    assert %{linear_access_token: ["can't be blank"]} = errors_on(changeset)
  end

  test "handles invalid string expires_in gracefully", %{scope: scope} do
    attrs = %{
      "access_token" => "at_invalid_exp",
      "refresh_token" => "rt_invalid_exp",
      "expires_in" => "invalid_sec"
    }

    assert {:error, changeset} = Users.link_linear(scope, attrs)
    assert %{linear_token_expires_at: ["can't be blank"]} = errors_on(changeset)
  end
end
