defmodule Rail.ScopeTest do
  use Rail.DataCase, async: true

  alias Rail.Scope

  test "for_user returns a scope with the given user map" do
    user = %{id: "usr_123", name: "Alice", admin: false}
    assert %Scope{user: ^user, system: false} = Scope.for_user(user)
  end

  test "for_user returns nil when user is nil" do
    assert is_nil(Scope.for_user(nil))
  end

  test "for_system returns a system scope" do
    assert %Scope{user: nil, system: true} = Scope.for_system()
  end

  test "admin? returns true for system scope" do
    assert Scope.admin?(Scope.for_system())
  end

  test "admin? returns true for user with admin flag" do
    scope = Scope.for_user(%{admin: true})
    assert Scope.admin?(scope)
  end

  test "admin? returns false for user without admin flag" do
    scope = Scope.for_user(%{admin: false})
    refute Scope.admin?(scope)

    empty_scope = %Scope{}
    refute Scope.admin?(empty_scope)
    refute Scope.admin?(nil)
  end

  test "user_scope builds default user scope" do
    assert %Scope{user: %{admin: false, linear_linked: false, id: id}, system: false} = Scope.user_scope()
    assert byte_size(id) > 0
  end

  test "user_scope supports admin and linear_linked options" do
    assert %Scope{user: %{admin: true, linear_linked: true}} =
             Scope.user_scope(admin: true, linear_linked: true)
  end

  test "user_scope supports custom user struct or map" do
    custom_user = %{id: "usr_custom", name: "Bob", admin: true}
    assert %Scope{user: ^custom_user} = Scope.user_scope(user: custom_user)
  end

  test "temp_user_scope delegates to user_scope" do
    assert %Scope{user: %{admin: true}} = Scope.temp_user_scope(admin: true)
  end

  test "system_scope returns system scope" do
    assert %Scope{user: nil, system: true} = Scope.system_scope()
  end

  test "project_ids is nil, meaning every project, for admins and the system scope" do
    assert Scope.project_ids(Scope.for_system()) == nil
    assert Scope.project_ids(Scope.for_user(%{admin: true, project_ids: ["prj_a"]})) == nil
    assert Scope.can_access_project?(Scope.for_system(), "prj_b")
    assert Scope.can_access_project?(Scope.for_user(%{admin: true, project_ids: []}), "prj_b")
  end

  test "project_ids is a user's granted projects, and an empty list when they have none" do
    scope = Scope.for_user(%{admin: false, project_ids: ["prj_a"]})
    assert Scope.project_ids(scope) == ["prj_a"]
    assert Scope.can_access_project?(scope, "prj_a")
    refute Scope.can_access_project?(scope, "prj_b")

    none = Scope.for_user(%{admin: false, project_ids: []})
    assert Scope.project_ids(none) == []
    refute Scope.can_access_project?(none, "prj_a")
    refute Scope.can_access_project?(none, nil)
  end

  test "user_scope accepts project ids" do
    assert %Scope{user: %{project_ids: []}} = Scope.user_scope()
    assert %Scope{user: %{project_ids: ["prj_a"]}} = Scope.user_scope(project_ids: ["prj_a"])
  end

  test "linear_linked? returns true when user has linear_access_token or linear_linked flag" do
    assert Scope.linear_linked?(%Scope{user: %{linear_access_token: "lin_at_valid"}})
    assert Scope.linear_linked?(%Scope{user: %{linear_linked: true}})
    refute Scope.linear_linked?(%Scope{user: %{linear_access_token: nil}})
    refute Scope.linear_linked?(%Scope{user: %{linear_access_token: ""}})
    refute Scope.linear_linked?(%Scope{user: %{linear_linked: false}})
    refute Scope.linear_linked?(%Scope{user: nil})
    refute Scope.linear_linked?(nil)
  end

  test "slack_linked? is true only when the user has a Slack token" do
    assert Scope.slack_linked?(%Scope{user: %{slack_access_token: "xoxp-1"}})
    refute Scope.slack_linked?(%Scope{user: %{slack_access_token: nil}})
    refute Scope.slack_linked?(%Scope{user: %{slack_access_token: ""}})
    refute Scope.slack_linked?(%Scope{user: %{admin: true}})
    refute Scope.slack_linked?(nil)
  end
end
