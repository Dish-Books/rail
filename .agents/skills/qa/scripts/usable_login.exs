# Repairs states the dev database can hold but production cannot, so a QA pass does not spend its
# first ten minutes on them. Run with: mix run usable_login.exs <email>
#
# Two states. An Organization whose onboarding is `complete` with no Subscription: sign-up
# subscribes before it completes, so production has no such row - but a dev database seeded or
# hand-edited before that was true does, and every LiveView then bounces off ForcedSubscription to
# /settings/billing, which a user with no role is refused, which redirects to /no-permission, which
# bounces again: the browser gives up with ERR_TOO_MANY_REDIRECTS and nothing can be QA'd. And a
# member row with no Role, which carries no permissions at all, so every screen refuses it and reads
# as a bug in whichever screen refused it last.
import Ecto.Query

alias Dishbooks.Billing
alias Dishbooks.Billing.Schemas.Subscription
alias Dishbooks.Repo
alias Dishbooks.Users.Schemas.Role
alias Dishbooks.Users.Schemas.User

if Application.get_env(:dishbooks, :config_env) == :prod do
  raise "usable_login.exs writes repair rows; never run it against production"
end

[email] =
  case System.argv() do
    [email] -> [email]
    _no_args -> raise "usage: mix run usable_login.exs <email>"
  end

case Repo.get_by(User, email: email) do
  nil ->
    IO.puts("USABLE_LOGIN unknown user #{email}; nothing to repair")

  %User{} = user ->
    organization_users =
      user
      |> Repo.preload(organization_users: :organization)
      |> Map.fetch!(:organization_users)

    repairs =
      Enum.flat_map(organization_users, fn organization_user ->
        organization = organization_user.organization
        subscribed? = Repo.exists?(from s in Subscription, where: s.organization_id == ^organization.id)

        subscription_repair =
          if organization.onboarding.status == :complete and not subscribed? do
            %Subscription{organization_id: organization.id}
            |> Subscription.create_changeset(%{
              status: :active,
              next_billing_at: DateTime.shift(DateTime.utc_now(), day: 30),
              plans: Billing.list_plans(filter: %{"lookup_key" => ["base"]})
            })
            |> Repo.insert!()

            ["gave #{organization.name || organization.id} the active Subscription its completed onboarding implies"]
          else
            []
          end

        # A role is what carries permissions, and create_organization has assigned the owner one
        # since roles existed. A member row without one can reach nothing and reads as a bug in
        # whatever screen refused it.
        role_repair =
          if is_nil(organization_user.role_id) do
            owner_role =
              Repo.get_by(Role, organization_id: organization.id, system_default: :owner) ||
                %Role{system_default: :owner, organization_id: organization.id}
                |> Role.changeset(%{name: "Owner", permissions: %{}})
                |> Repo.insert!()

            organization_user
            |> Ecto.Changeset.change(role_id: owner_role.id)
            |> Repo.update!()

            ["gave #{email} the Owner role in #{organization.name || organization.id}"]
          else
            []
          end

        subscription_repair ++ role_repair
      end)

    case repairs do
      [] -> IO.puts("USABLE_LOGIN #{email} can use the app; nothing to repair")
      repairs -> Enum.each(repairs, fn repair -> IO.puts("USABLE_LOGIN #{repair}") end)
    end
end
