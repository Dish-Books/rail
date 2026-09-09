defmodule Rail.Users.Actions.CanTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Users

  describe "can?/2" do
    test "system scope can do everything" do
      scope = Scope.for_system()
      assert Users.can?(scope, :list_users)
      assert Users.can?(scope, :manage_projects)
      assert Users.can?(scope, :any_other_action)
    end

    test "nil or unauthenticated scope cannot do anything" do
      refute Users.can?(nil, :list_users)
      refute Users.can?(nil, :any_action)
      refute Users.can?(%Scope{user: nil}, :list_users)
    end

    test "admin scope can perform admin actions" do
      scope = Scope.for_user(%{admin: true})
      assert Users.can?(scope, :list_users)
      assert Users.can?(scope, :manage_users)
      assert Users.can?(scope, :manage_projects)
      assert Users.can?(scope, :manage_roles)
      assert Users.can?(scope, :manage_linear_workspace)
      assert Users.can?(scope, :create_task)
    end

    test "non-admin scope cannot perform admin actions but can do regular actions" do
      scope = Scope.for_user(%{admin: false})
      refute Users.can?(scope, :list_users)
      refute Users.can?(scope, :manage_users)
      refute Users.can?(scope, :manage_projects)
      refute Users.can?(scope, :manage_roles)
      refute Users.can?(scope, :manage_linear_workspace)
      assert Users.can?(scope, :create_task)
    end
  end

  describe "can?/3" do
    test "system scope can do everything" do
      scope = Scope.for_system()
      assert Users.can?(scope, :users, :manage)
      assert Users.can?(scope, :projects, :manage)
      assert Users.can?(scope, :roles, :manage)
      assert Users.can?(scope, :tasks, :create)
    end

    test "nil or unauthenticated scope cannot do anything" do
      refute Users.can?(nil, :projects, :view)
      refute Users.can?(%Scope{user: nil}, :projects, :view)
    end

    test "admin scope can manage admin resources and view users" do
      scope = Scope.for_user(%{admin: true})
      assert Users.can?(scope, :users, :manage)
      assert Users.can?(scope, :users, :view)
      assert Users.can?(scope, :users, :list)
      assert Users.can?(scope, :projects, :manage)
      assert Users.can?(scope, :roles, :manage)
      assert Users.can?(scope, :linear_workspace, :manage)
      assert Users.can?(scope, :tasks, :manage)
    end

    test "non-admin scope cannot manage admin resources or view users" do
      scope = Scope.for_user(%{admin: false})
      refute Users.can?(scope, :users, :manage)
      refute Users.can?(scope, :users, :view)
      refute Users.can?(scope, :users, :list)
      refute Users.can?(scope, :projects, :manage)
      refute Users.can?(scope, :roles, :manage)
      refute Users.can?(scope, :linear_workspace, :manage)
    end

    test "non-admin scope can view projects and roles and do project internal work" do
      scope = Scope.for_user(%{admin: false})
      assert Users.can?(scope, :projects, :view)
      assert Users.can?(scope, :roles, :view)
      assert Users.can?(scope, :tasks, :view)
      assert Users.can?(scope, :tasks, :create)
      assert Users.can?(scope, :issues, :view)
    end
  end
end
