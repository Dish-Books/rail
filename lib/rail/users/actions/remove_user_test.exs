defmodule Rail.Users.Actions.RemoveUserTest do
  use Rail.DataCase, async: true

  alias Rail.Mcp
  alias Rail.Mcp.Schemas.OauthAccessToken
  alias Rail.Mcp.Schemas.OauthRefreshToken
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.Invite
  alias Rail.Users.Schemas.User
  alias Ueberauth.Auth
  alias Ueberauth.Auth.Credentials
  alias Ueberauth.Auth.Info

  setup do
    id = System.unique_integer([:positive])

    {:ok, admin} =
      Users.register_oauth_user(%{
        github_id: "rm_admin_#{id}",
        login: "rm_admin_#{id}",
        email: "rm_admin_#{id}@example.com",
        admin: true
      })

    scope = Scope.for_user(admin)
    email = "leaver_#{id}@example.com"

    auth = %Auth{
      provider: :github,
      uid: "leaver_gh_#{id}",
      info: %Info{nickname: "leaver_#{id}", name: "Leaver #{id}", email: email},
      credentials: %Credentials{token: "gho_#{id}"}
    }

    {:ok, %Invite{}} = Users.invite_user(scope, %{email: email, project_ids: ["prj_a"]})
    {:ok, leaver} = Users.sign_in_oauth_user(auth)
    {:ok, %User{id: leaver_id} = leaver} = Users.update_user(scope, leaver, %{admin: true, tech_lead: true})

    %{scope: scope, admin: admin, leaver: leaver, leaver_id: leaver_id, auth: auth, email: email}
  end

  test "keeps the row but signs them out, drops what they were granted and says so", %{
    scope: scope,
    leaver: leaver,
    leaver_id: leaver_id
  } do
    token = Users.generate_user_session_token(leaver)
    Phoenix.PubSub.subscribe(Rail.PubSub, "users")
    Phoenix.PubSub.subscribe(Rail.PubSub, "user:#{leaver_id}")

    assert {:ok, %User{id: ^leaver_id, removed_at: %DateTime{}, admin: false, tech_lead: false}} =
             Users.remove_user(scope, leaver_id)

    assert %User{removed_at: %DateTime{}} = Repo.get(User, leaver_id)
    assert Users.get_user_by_session_token(token) == nil
    assert_receive {:users_changed, ^leaver_id}
    assert_receive {:user_removed, ^leaver_id}
  end

  test "revokes their MCP connections", %{scope: scope, leaver: leaver, leaver_id: leaver_id} do
    {:ok, client, nil} = Mcp.register_dynamic_client(%{"redirect_uris" => ["http://localhost/callback"]})
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, %{redirect_url: url}} =
      Mcp.authorize(Scope.for_user(leaver), %{
        "client_id" => client.client_id,
        "redirect_uri" => "http://localhost/callback",
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
        "code_challenge_method" => "S256"
      })

    {:ok, %{access_token: access_token}} =
      Mcp.exchange_code(client, %{
        "grant_type" => "authorization_code",
        "code" => URI.decode_query(URI.parse(url).query)["code"],
        "redirect_uri" => "http://localhost/callback",
        "code_verifier" => verifier
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "mcp_authorizations")

    assert {:ok, _user} = Users.remove_user(scope, leaver_id)

    assert {:error, :revoked} = Mcp.resolve_access_token(access_token)
    assert Repo.all(from t in OauthAccessToken, where: t.user_id == ^leaver_id and is_nil(t.revoked_at)) == []
    assert Repo.all(from t in OauthRefreshToken, where: t.user_id == ^leaver_id and is_nil(t.revoked_at)) == []
    assert_receive {:mcp_authorizations_changed, ^leaver_id}
  end

  test "turns both kinds of their Slack notification off", %{scope: scope, leaver: leaver, leaver_id: leaver_id} do
    {:ok, linked} = Users.update_user(scope, leaver, %{slack_user_id: "U1", slack_team_id: "T1"})

    {:ok, _on} =
      linked
      |> User.slack_notifications_changeset(%{slack_notifications: true, slack_support_notifications: true})
      |> Repo.update()

    assert {:ok, %User{id: ^leaver_id, slack_notifications: false, slack_support_notifications: false}} =
             Users.remove_user(scope, leaver_id)
  end

  test "leaves them off the lists of people", %{scope: scope, leaver: leaver} do
    {:ok, _user} = Users.remove_user(scope, leaver.id)

    {:ok, users} = Users.list_users(scope)
    refute Enum.any?(users, &(&1.id == leaver.id))
    refute Enum.any?(Users.list_assignable_users(), &(&1.id == leaver.id))
    refute Enum.any?(Users.list_tech_leads("prj_a"), &(&1.id == leaver.id))
  end

  test "they cannot sign back in without a new invite, which restores them on its own terms", %{
    scope: scope,
    leaver: leaver,
    leaver_id: leaver_id,
    auth: auth,
    email: email
  } do
    {:ok, _user} = Users.remove_user(scope, leaver.id)

    assert {:error, :not_invited} = Users.sign_in_oauth_user(auth)

    assert {:ok, %Invite{accepted_at: nil, accepted_user_id: nil}} =
             Users.invite_user(scope, %{email: email, role: :tester, project_ids: ["prj_b"]})

    assert {:ok, invites} = Users.list_invites(scope)
    assert Enum.any?(invites, &(&1.email == email))

    assert {:ok, %User{id: ^leaver_id, removed_at: nil, admin: false, role: :tester, project_ids: ["prj_b"]}} =
             Users.sign_in_oauth_user(auth)
  end

  test "someone still in Rail cannot be invited again", %{scope: scope, email: email} do
    assert {:error, :already_accepted} = Users.invite_user(scope, %{email: email})
  end

  test "an admin cannot remove themselves", %{scope: scope, admin: admin} do
    assert {:error, :self} = Users.remove_user(scope, admin.id)
    assert %User{removed_at: nil} = Repo.get(User, admin.id)
  end

  test "someone already removed, or never there, is not found", %{scope: scope, leaver: leaver} do
    {:ok, _user} = Users.remove_user(scope, leaver.id)

    assert {:error, :not_found} = Users.remove_user(scope, leaver.id)
    assert {:error, :not_found} = Users.remove_user(scope, "usr_missing")
  end

  test "only an admin can remove someone", %{admin: admin, leaver: leaver} do
    {:ok, leaver} = Users.update_user(Scope.for_system(), leaver, %{admin: false})

    assert {:error, :not_authorized} = Users.remove_user(Scope.for_user(leaver), admin.id)
    assert %User{removed_at: nil} = Repo.get(User, admin.id)
  end
end
