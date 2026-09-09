alias Dishbooks.Repo
alias Dishbooks.Transactions.Schemas.GLAccount
alias Dishbooks.Transactions.Schemas.GLType
import Ecto.Query

action = System.argv() |> List.first() || "create"
org_id = "org_01kt20xzedtqf5z2v0fd23mqj1"

case action do
  "create" ->
    from(g in GLAccount, where: g.organization_id == ^org_id and g.number == "5990") |> Repo.delete_all()
    gl_type = Repo.get_by!(GLType, organization_id: org_id, name: "Food Cost")
    {:ok, user} = Dishbooks.Users.get_user_by_email("michael@dishbooks.com")
    user = Repo.preload(user, [organization_users: [:organization, :role]])
    scope = Dishbooks.Scope.for_user(user, org_id)

    {:ok, account} =
      Dishbooks.Transactions.create_gl_account(scope, %{
        name: "Specialty Kitchen Supplies",
        number: "5990",
        gl_type_id: gl_type.id
      })
    IO.puts("CREATED #{account.id}")

  "delete" ->
    from(g in GLAccount, where: g.organization_id == ^org_id and g.number == "5990") |> Repo.delete_all()
    IO.puts("DELETED")
end
