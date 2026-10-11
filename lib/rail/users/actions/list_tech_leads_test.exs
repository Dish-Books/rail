defmodule Rail.Users.Actions.ListTechLeadsTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Schemas.User

  test "lists the tech leads granted the project and the admin tech leads, by name, and nobody else" do
    register = fn login, attrs ->
      {:ok, user} = Users.register_oauth_user(%{github_id: "gh_#{login}", login: login, email: "#{login}@example.com"})
      {:ok, user} = Users.update_user(system_scope(), user, attrs)
      user
    end

    %User{id: priya_id} = register.("priya", %{name: "Priya Raman", tech_lead: true, project_ids: ["prj_tl"]})
    %User{id: michael_id} = register.("mkerr", %{name: "Michael Kerr", tech_lead: true, admin: true})
    %User{} = register.("dano", %{name: "Dan Okafor", project_ids: ["prj_tl"]})
    %User{} = register.("admin", %{name: "Ada Admin", admin: true})
    %User{} = register.("sam", %{name: "Sam Ito", tech_lead: true, project_ids: ["prj_other"]})

    assert [%User{id: ^michael_id}, %User{id: ^priya_id}] = Users.list_tech_leads("prj_tl")
  end
end
