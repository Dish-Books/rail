defmodule Rail.Linear.ClientTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.Linear

  alias Rail.Linear
  alias Rail.Linear.Client

  describe "authorize_url/1" do
    test "builds default authorize URL with configured parameters" do
      url = Client.authorize_url()

      assert String.starts_with?(url, "https://linear.app/oauth/authorize?")
      assert String.contains?(url, "client_id=test_linear_client_id")
      assert String.contains?(url, "redirect_uri=http%3A%2F%2Flocalhost%3A4002%2Fauth%2Flinear%2Fcallback")
      assert String.contains?(url, "response_type=code")
      assert String.contains?(url, "actor=user")
      assert String.contains?(url, "scope=read%2Cwrite%2Cissues%3Acreate%2Ccomments%3Acreate")
      refute String.contains?(url, "state=")
    end

    test "includes state parameter and allows overriding options" do
      url =
        Client.authorize_url(
          client_id: "custom_client",
          redirect_uri: "https://example.com/callback",
          state: "csrf_state_123",
          scope: "read"
        )

      assert String.contains?(url, "client_id=custom_client")
      assert String.contains?(url, "redirect_uri=https%3A%2F%2Fexample.com%2Fcallback")
      assert String.contains?(url, "state=csrf_state_123")
      assert String.contains?(url, "scope=read")
    end

    test "Rail.Linear delegates authorize_url" do
      assert Linear.authorize_url() == Client.authorize_url()
    end
  end

  describe "exchange_code/2" do
    test "exchanges code for tokens successfully" do
      mock_exchange_success(
        access_token: "lin_access_test_token",
        refresh_token: "lin_refresh_test_token",
        expires_in: 7200
      )

      assert {:ok,
              %{
                access_token: "lin_access_test_token",
                refresh_token: "lin_refresh_test_token",
                expires_in: 7200,
                expires_at: %DateTime{},
                scope: ["read", "write", "issues:create", "comments:create"]
              }} = Client.exchange_code("valid_auth_code")
    end

    test "returns error on token endpoint failure" do
      mock_exchange_error(400, "invalid_grant")

      assert {:error, {:linear_oauth_error, 400, %{"error" => "invalid_grant"}}} =
               Client.exchange_code("invalid_code")
    end

    test "returns error on network transport failure" do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.exchange_code("some_code")
    end

    test "Rail.Linear delegates exchange_code" do
      mock_exchange_success(access_token: "delegated_access_token")

      assert {:ok, %{access_token: "delegated_access_token"}} =
               Linear.exchange_code("code_for_delegate")
    end
  end

  describe "refresh_token/2" do
    test "refreshes access token successfully" do
      mock_refresh_success(
        access_token: "lin_new_access_token",
        refresh_token: "lin_new_refresh_token",
        expires_in: 3600
      )

      assert {:ok,
              %{
                access_token: "lin_new_access_token",
                refresh_token: "lin_new_refresh_token",
                expires_in: 3600,
                expires_at: %DateTime{}
              }} = Client.refresh_token("existing_refresh_token")
    end

    test "returns error on refresh failure" do
      mock_refresh_error(400, "invalid_grant")

      assert {:error, {:linear_token_refresh_error, 400, %{"error" => "invalid_grant"}}} =
               Client.refresh_token("expired_refresh_token")
    end

    test "returns error on transport error during refresh" do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Client.refresh_token("timeout_token")
    end

    test "Rail.Linear delegates refresh_token" do
      mock_refresh_success(access_token: "delegated_refresh_at")

      assert {:ok, %{access_token: "delegated_refresh_at"}} =
               Linear.refresh_token("rt_for_delegate")
    end
  end

  describe "viewer/2" do
    test "queries viewer successfully" do
      mock_viewer_success(id: "viewer_usr_456", name: "Alice Linear")

      assert {:ok, %{id: "viewer_usr_456", name: "Alice Linear"}} =
               Client.viewer("valid_access_token")
    end

    test "returns error on API error response" do
      mock_viewer_error(401)

      assert {:error, {:linear_api_error, 401, %{"errors" => _errors}}} =
               Client.viewer("bad_token")
    end

    test "returns error on transport error during viewer query" do
      Req.Test.expect(Linear, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      assert {:error, %Req.TransportError{reason: :nxdomain}} =
               Client.viewer("token_nxdomain")
    end

    test "Rail.Linear delegates viewer" do
      mock_viewer_success(id: "delegate_viewer_id", name: "Bob Linear")

      assert {:ok, %{id: "delegate_viewer_id", name: "Bob Linear"}} =
               Linear.viewer("token_for_delegate")
    end
  end
end
