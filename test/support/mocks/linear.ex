defmodule RailTest.Mocks.Linear do
  @moduledoc false

  import ExUnit.Assertions
  import Plug.Conn

  def mock_exchange_success(opts \\ []) do
    token = Keyword.get(opts, :access_token, "mock_linear_access_token")
    refresh = Keyword.get(opts, :refresh_token, "mock_linear_refresh_token")
    expires_in = Keyword.get(opts, :expires_in, 3600)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/oauth/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["grant_type"] == "authorization_code"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "access_token" => token,
          "token_type" => "Bearer",
          "expires_in" => expires_in,
          "refresh_token" => refresh,
          "scope" => ["read", "write", "issues:create", "comments:create"]
        })
      )
    end)
  end

  def mock_exchange_error(status \\ 400, error \\ "invalid_grant") do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/oauth/token"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        status,
        Jason.encode!(%{
          "error" => error,
          "error_description" => "Invalid authorization code"
        })
      )
    end)
  end

  def mock_refresh_success(opts \\ []) do
    token = Keyword.get(opts, :access_token, "mock_refreshed_access_token")
    refresh = Keyword.get(opts, :refresh_token, "mock_refreshed_refresh_token")
    expires_in = Keyword.get(opts, :expires_in, 3600)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/oauth/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["grant_type"] == "refresh_token"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "access_token" => token,
          "token_type" => "Bearer",
          "expires_in" => expires_in,
          "refresh_token" => refresh
        })
      )
    end)
  end

  def mock_refresh_error(status \\ 400, error \\ "invalid_grant") do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/oauth/token"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        status,
        Jason.encode!(%{
          "error" => error,
          "error_description" => "Invalid refresh token"
        })
      )
    end)
  end

  def mock_viewer_success(opts \\ []) do
    id = Keyword.get(opts, :id, "lin_usr_123")
    name = Keyword.get(opts, :name, "Linear Test User")

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "viewer" => %{
              "id" => id,
              "name" => name
            }
          }
        })
      )
    end)
  end

  def mock_viewer_error(status \\ 401) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        status,
        Jason.encode!(%{
          "errors" => [%{"message" => "Not authenticated"}]
        })
      )
    end)
  end
end
