defmodule Rail.PermissionsDecoratorTest do
  use Rail.DataCase, async: true

  alias Rail.Scope

  defmodule TestActions do
    @moduledoc false
    use Rail.PermissionsDecorator

    @decorate can?(resource: :projects, action: :create)
    def create_project(scope, attrs) do
      {:ok, Map.put(attrs, :scope_system, scope.system)}
    end

    @decorate can?(resource: :projects, action: :view)
    def get_project(scope, id) do
      {:ok, {scope, id}}
    end

    @decorate can?(:create_project)
    def create_project_atom(scope, attrs) do
      {:ok, {scope, attrs}}
    end

    @decorate can?(action: :create_project)
    def create_project_keyword_action(scope, attrs) do
      {:ok, {scope, attrs}}
    end

    @decorate can?(any: [{:roles, :manage}, {:projects, :create}])
    def manage_any_tuple(scope, arg) do
      {:ok, {scope, arg}}
    end

    @decorate can?(any: [:create_project, :manage_roles])
    def manage_any_atom(scope, arg) do
      {:ok, {scope, arg}}
    end
  end

  describe "resource and action keyword syntax" do
    test "system scope passes" do
      scope = Scope.for_system()
      assert {:ok, %{scope_system: true}} = TestActions.create_project(scope, %{name: "Test"})
      assert {:ok, {^scope, "prj_123"}} = TestActions.get_project(scope, "prj_123")
    end

    test "admin user scope passes" do
      scope = Scope.user_scope(admin: true)
      assert {:ok, %{scope_system: false}} = TestActions.create_project(scope, %{name: "Test"})
      assert {:ok, {^scope, "prj_123"}} = TestActions.get_project(scope, "prj_123")
    end

    test "regular user scope passes view but denied manage/create" do
      scope = Scope.user_scope(admin: false)
      assert {:ok, {^scope, "prj_123"}} = TestActions.get_project(scope, "prj_123")
      assert {:error, :not_authorized} = TestActions.create_project(scope, %{name: "Test"})
    end

    test "nil or user: nil scope is denied" do
      assert {:error, :not_authorized} = TestActions.create_project(nil, %{name: "Test"})
      assert {:error, :not_authorized} = TestActions.create_project(%Scope{user: nil}, %{name: "Test"})
      assert {:error, :not_authorized} = TestActions.get_project(nil, "prj_123")
      assert {:error, :not_authorized} = TestActions.get_project(%Scope{user: nil}, "prj_123")
    end

    test "authorized execution passes arguments through" do
      scope = Scope.for_system()
      attrs = %{name: "My Project", key: "MP"}
      assert {:ok, %{name: "My Project", key: "MP", scope_system: true}} = TestActions.create_project(scope, attrs)
    end
  end

  describe "atom action syntax" do
    test "system and admin user scopes pass" do
      sys = Scope.for_system()
      admin = Scope.user_scope(admin: true)
      assert {:ok, {^sys, %{test: 1}}} = TestActions.create_project_atom(sys, %{test: 1})
      assert {:ok, {^admin, %{test: 2}}} = TestActions.create_project_atom(admin, %{test: 2})
    end

    test "regular user and unauthenticated scopes are denied" do
      assert {:error, :not_authorized} = TestActions.create_project_atom(Scope.user_scope(admin: false), %{test: 1})
      assert {:error, :not_authorized} = TestActions.create_project_atom(nil, %{test: 1})
      assert {:error, :not_authorized} = TestActions.create_project_atom(%Scope{user: nil}, %{test: 1})
    end
  end

  describe "action keyword syntax" do
    test "system and admin user scopes pass" do
      sys = Scope.for_system()
      admin = Scope.user_scope(admin: true)

      assert {:ok, {^sys, %{test: 1}}} =
               TestActions.create_project_keyword_action(sys, %{test: 1})

      assert {:ok, {^admin, %{test: 2}}} =
               TestActions.create_project_keyword_action(admin, %{test: 2})
    end

    test "regular user and unauthenticated scopes are denied" do
      assert {:error, :not_authorized} =
               TestActions.create_project_keyword_action(Scope.user_scope(admin: false), %{test: 1})

      assert {:error, :not_authorized} = TestActions.create_project_keyword_action(nil, %{test: 1})
      assert {:error, :not_authorized} = TestActions.create_project_keyword_action(%Scope{user: nil}, %{test: 1})
    end
  end

  describe "any requirements syntax" do
    test "passes when satisfying at least one requirement with tuple" do
      admin = Scope.user_scope(admin: true)
      sys = Scope.for_system()
      assert {:ok, {^admin, "arg"}} = TestActions.manage_any_tuple(admin, "arg")
      assert {:ok, {^sys, "arg"}} = TestActions.manage_any_tuple(sys, "arg")
      assert {:error, :not_authorized} = TestActions.manage_any_tuple(Scope.user_scope(admin: false), "arg")
      assert {:error, :not_authorized} = TestActions.manage_any_tuple(nil, "arg")
    end

    test "passes when satisfying at least one requirement with atom" do
      admin = Scope.user_scope(admin: true)
      sys = Scope.for_system()
      assert {:ok, {^admin, "arg"}} = TestActions.manage_any_atom(admin, "arg")
      assert {:ok, {^sys, "arg"}} = TestActions.manage_any_atom(sys, "arg")
      assert {:error, :not_authorized} = TestActions.manage_any_atom(Scope.user_scope(admin: false), "arg")
      assert {:error, :not_authorized} = TestActions.manage_any_atom(nil, "arg")
    end
  end
end
