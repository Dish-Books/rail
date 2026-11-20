defmodule Rail.Users.Actions.LinkIntercomTest do
  use Rail.DataCase, async: true

  alias Rail.Scope
  alias Rail.Support
  alias Rail.Users
  alias Rail.Users.Schemas.User

  setup %{project: project} do
    unique = System.unique_integer([:positive])
    app_id = "app#{unique}"

    {:ok, user} =
      Users.register_oauth_user(%{github_id: "li_#{unique}", login: "li_#{unique}", email: "li_#{unique}@example.com"})

    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"app" => %{"id_code" => app_id}}))

    {:ok, workspace} =
      Support.create_intercom_workspace(system_scope(), project, %{
        "name" => "Support",
        "access_token" => "workspace-token",
        "client_id" => "cid",
        "client_secret" => "secret"
      })

    Phoenix.PubSub.subscribe(Rail.PubSub, "users")

    %{user: user, scope: Scope.for_user(user), workspace: workspace, app_id: app_id}
  end

  test "trades the code for the person's token and stores who Intercom says they are", %{
    user: %{id: user_id},
    scope: scope,
    workspace: workspace,
    app_id: app_id
  } do
    Req.Test.expect(Rail.Intercom, fn conn ->
      assert conn.request_path == "/auth/eagle/token"

      assert %{"code" => "c0de", "client_id" => "cid", "client_secret" => "secret"} =
               Plug.Conn.Query.decode(Req.Test.raw_body(conn))

      Req.Test.json(conn, %{"access_token" => "dana-token"})
    end)

    Req.Test.expect(Rail.Intercom, fn conn ->
      assert conn.request_path == "/me"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer dana-token"]

      Req.Test.json(conn, %{
        "id" => 991,
        "name" => "Dana Whitfield",
        "email_verified" => true,
        "app" => %{"id_code" => app_id}
      })
    end)

    assert {:ok,
            %User{
              id: ^user_id,
              intercom_admin_id: "991",
              intercom_app_id: ^app_id,
              intercom_name: "Dana Whitfield",
              intercom_access_token: "dana-token"
            }} = Users.link_intercom(scope, workspace, "c0de")

    assert_receive {:users_changed, ^user_id}
  end

  test "an account whose email Intercom has not verified is refused", %{
    scope: scope,
    workspace: workspace,
    app_id: app_id
  } do
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"access_token" => "tok"}))

    Req.Test.expect(
      Rail.Intercom,
      &Req.Test.json(&1, %{"id" => 1, "email_verified" => false, "app" => %{"id_code" => app_id}})
    )

    assert {:error, :intercom_account_not_accepted} = Users.link_intercom(scope, workspace, "c0de")
    assert %User{intercom_access_token: nil} = Repo.get!(User, scope.user.id)
  end

  test "an account in another Intercom app is refused", %{scope: scope, workspace: workspace} do
    Req.Test.expect(Rail.Intercom, &Req.Test.json(&1, %{"access_token" => "tok"}))

    Req.Test.expect(
      Rail.Intercom,
      &Req.Test.json(&1, %{"id" => 1, "email_verified" => true, "app" => %{"id_code" => "someone_else"}})
    )

    assert {:error, :intercom_account_not_accepted} = Users.link_intercom(scope, workspace, "c0de")
  end

  test "a code Intercom refuses is passed on", %{scope: scope, workspace: workspace} do
    Req.Test.expect(Rail.Intercom, &(&1 |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "bad code"})))

    assert {:error, {:intercom_error, 401, %{"error" => "bad code"}}} = Users.link_intercom(scope, workspace, "c0de")
  end

  test "needs a signed-in user", %{workspace: workspace} do
    assert {:error, :not_authenticated} = Users.link_intercom(Scope.for_system(), workspace, "c0de")
  end
end
