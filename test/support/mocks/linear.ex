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
    email = Keyword.get(opts, :email, "user@example.com")

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
              "name" => name,
              "email" => email
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

  def mock_issues_success(nodes, _opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "team" => %{
              "issues" => %{
                "nodes" => nodes
              }
            }
          }
        })
      )
    end)
  end

  def mock_issue_success(issue, _opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issue" => issue
          }
        })
      )
    end)
  end

  def mock_issue_not_found(_opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issue" => nil
          }
        })
      )
    end)
  end

  def mock_create_issue_success(issue, _opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueCreate" => %{
              "success" => true,
              "issue" => issue
            }
          }
        })
      )
    end)
  end

  def mock_update_issue_success(issue, _opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "issueUpdate" => %{
              "success" => true,
              "issue" => issue
            }
          }
        })
      )
    end)
  end

  def mock_workflow_states_success(states, _opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "team" => %{
              "states" => %{
                "nodes" => states
              }
            }
          }
        })
      )
    end)
  end

  def mock_file_upload_success(opts \\ []) do
    upload_url = Keyword.get(opts, :upload_url, "https://api.linear.app/upload/asset_123")
    asset_url = Keyword.get(opts, :asset_url, "https://uploads.linear.app/asset_123/file.png")
    asset_id = Keyword.get(opts, :asset_id, "asset_123")
    put_status = Keyword.get(opts, :put_status, 200)
    put_error = Keyword.get(opts, :put_error)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "fileUpload" => %{
              "success" => true,
              "uploadFile" => %{
                "id" => asset_id,
                "uploadUrl" => upload_url,
                "assetUrl" => asset_url,
                "headers" => [%{"key" => "Content-Type", "value" => "image/png"}]
              }
            }
          }
        })
      )
    end)

    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.method == "PUT"

      if put_error do
        Req.Test.transport_error(conn, put_error)
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(put_status, "")
      end
    end)
  end

  def mock_create_comment_success(comment, _opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "commentCreate" => %{
              "success" => true,
              "comment" => comment
            }
          }
        })
      )
    end)
  end

  def mock_attachment_create_success(attachment, _opts \\ []) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "attachmentCreate" => %{
              "success" => true,
              "attachment" => attachment
            }
          }
        })
      )
    end)
  end

  def mock_graphql_error(errors \\ [%{"message" => "GraphQL query error"}]) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "errors" => errors
        })
      )
    end)
  end

  def mock_mutation_failure(mutation_name) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            mutation_name => %{"success" => false}
          }
        })
      )
    end)
  end

  def mock_api_error(status \\ 500, body \\ %{"error" => "Internal error"}) do
    Req.Test.expect(Rail.Linear, fn conn ->
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
    end)
  end
end
