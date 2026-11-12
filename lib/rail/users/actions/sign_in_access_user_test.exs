defmodule Rail.Users.Actions.SignInAccessUserTest do
  use Rail.DataCase, async: true

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Clients.CloudflareAccess
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048}), forger: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    id = System.unique_integer([:positive])
    stub(Rail, :cloudflare_access, fn -> %{team_domain: "team.cloudflareaccess.com", aud: "rail-aud"} end)
    {_kty, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    Req.Test.stub(CloudflareAccess, fn %{host: "team.cloudflareaccess.com", request_path: "/cdn-cgi/access/certs"} = conn ->
      Req.Test.json(conn, %{"keys" => [public]})
    end)

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "access_admin_#{id}",
        login: "access-admin-#{id}",
        email: "admin-#{id}@x.io"
      })

    {:ok, admin} = Users.update_user(Scope.for_system(), admin, %{admin: true})

    claims = %{
      "email" => "luis-#{id}@dishbooks.com",
      "iss" => "https://team.cloudflareaccess.com",
      "aud" => ["rail-aud"],
      "exp" => System.os_time(:second) + 300
    }

    %{admin: admin, claims: claims, email: claims["email"]}
  end

  test "signs in an invited email with the invite's projects, named for its local part, and stamps the invite", %{
    key: key,
    admin: admin,
    claims: claims,
    email: email,
    project: %{id: project_id}
  } do
    {:ok, %Invite{id: invite_id}} = Users.invite_user(Scope.for_user(admin), %{email: email, project_ids: [project_id]})
    Phoenix.PubSub.subscribe(Rail.PubSub, "users")
    {_jws, token} = key |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

    assert {:ok, %User{id: user_id, email: ^email, github_id: nil, login: nil, admin: false, project_ids: [^project_id]}} =
             Users.sign_in_access_user(token)

    assert %User{name: "luis-" <> _id} = Repo.get!(User, user_id)
    assert %Invite{accepted_user_id: ^user_id, accepted_at: %DateTime{}} = Repo.get!(Invite, invite_id)
    assert_receive {:users_changed, ^user_id}
  end

  test "signs a returning developer in to their account by email, leaving their GitHub as it was", %{
    key: key,
    claims: claims,
    email: email
  } do
    {:ok, %User{id: user_id}} =
      Users.register_oauth_user(%{github_id: "gh_returning", login: "returning", name: "Ret Urning", email: email})

    {_jws, token} = key |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

    assert {:ok, %User{id: ^user_id, github_id: "gh_returning", login: "returning", name: "Ret Urning"}} =
             Users.sign_in_access_user(token)
  end

  test "refuses an address with no account and no open invite, naming it", %{key: key, claims: claims, email: email} do
    {_jws, token} = key |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

    assert {:error, {:not_invited, ^email}} = Users.sign_in_access_user(token)
    assert {:error, :not_found} = Users.get_user(email: email)
  end

  test "refuses a forged, expired, other application's, other team's or emailless token, and a string that is no token",
       %{key: key, forger: forger, claims: claims, email: email} do
    {:ok, _invite} = Users.invite_user(Scope.for_system(), %{email: email})
    sign = fn jwk, fields -> jwk |> JOSE.JWT.sign(%{"alg" => "RS256"}, fields) |> JOSE.JWS.compact() |> elem(1) end

    refused = [
      sign.(forger, claims),
      sign.(key, %{claims | "exp" => System.os_time(:second) - 1}),
      sign.(key, %{claims | "aud" => ["another-app"]}),
      sign.(key, %{claims | "iss" => "https://other.cloudflareaccess.com"}),
      sign.(key, Map.delete(claims, "email")),
      # A service token, which Access issues with an empty identity.
      sign.(key, %{claims | "email" => ""}),
      "not-a-token"
    ]

    for token <- refused, do: assert({:error, :invalid_assertion} = Users.sign_in_access_user(token))
    assert {:error, :not_found} = Users.get_user(email: email)
  end

  test "trusts nothing while Access is not set up", %{key: key, claims: claims, email: email} do
    stub(Rail, :cloudflare_access, fn -> nil end)
    {_jws, token} = key |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

    assert {:error, :access_off} = Users.sign_in_access_user(token)
    assert {:error, :not_found} = Users.get_user(email: email)
  end

  test "signs nobody in when the team's keys cannot be read", %{key: key, claims: claims, email: email} do
    {_jws, token} = key |> JOSE.JWT.sign(%{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

    Req.Test.stub(CloudflareAccess, &(&1 |> Plug.Conn.put_status(503) |> Req.Test.json(%{})))
    assert {:error, {:access_unreachable, {:cloudflare_access_error, 503, %{}}}} = Users.sign_in_access_user(token)

    Req.Test.stub(CloudflareAccess, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, {:access_unreachable, %Req.TransportError{reason: :econnrefused}}} =
             Users.sign_in_access_user(token)

    assert {:error, :not_found} = Users.get_user(email: email)
  end
end
