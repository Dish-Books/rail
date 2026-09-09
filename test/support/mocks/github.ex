defmodule RailTest.Mocks.GitHub do
  @moduledoc false

  import ExUnit.Assertions
  import Plug.Conn

  def mock_installation_token_success(opts \\ []) do
    installation_id = Keyword.get(opts, :installation_id, 123)
    token = Keyword.get(opts, :token, "mock_installation_token")
    expires_at = Keyword.get(opts, :expires_at, "2026-09-09T14:00:00Z")

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/app/installations/#{installation_id}/access_tokens"
      [auth] = get_req_header(conn, "authorization")
      assert String.starts_with?(auth, "Bearer ")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        201,
        Jason.encode!(%{
          "token" => token,
          "expires_at" => expires_at,
          "permissions" => %{},
          "repository_selection" => "all"
        })
      )
    end)
  end

  def mock_installation_token_error(status \\ 401, error \\ "Bad credentials", opts \\ []) do
    installation_id = Keyword.get(opts, :installation_id, 123)

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/app/installations/#{installation_id}/access_tokens"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => error}))
    end)
  end

  def mock_list_installation_repositories_success(opts \\ []) do
    repos =
      Keyword.get(opts, :repositories, [
        %{
          "id" => 1,
          "name" => "test-repo",
          "full_name" => "owner/test-repo",
          "default_branch" => "main"
        }
      ])

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/installation/repositories"
      [auth] = get_req_header(conn, "authorization")
      assert String.starts_with?(auth, "Bearer ")

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "total_count" => length(repos),
          "repositories" => repos
        })
      )
    end)
  end

  def mock_list_installation_repositories_error(status \\ 401, error \\ "Bad credentials") do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/installation/repositories"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => error}))
    end)
  end

  def mock_pull_request_state_success(repo, pr_number, opts \\ []) do
    mergeable = Keyword.get(opts, :mergeable, true)
    draft = Keyword.get(opts, :draft, false)

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "number" => pr_number,
          "mergeable" => mergeable,
          "draft" => draft
        })
      )
    end)
  end

  def mock_pull_request_state_error(repo, pr_number, status \\ 404, message \\ "Not Found") do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => message}))
    end)
  end

  def mock_merge_pull_request_success(repo, pr_number, opts \\ []) do
    user_token = Keyword.get(opts, :user_token)
    merge_method = Keyword.get(opts, :merge_method, "squash")
    sha = Keyword.get(opts, :sha, "6dcb09b5b57875f334f61aebed695e2e4193db5e")
    message = Keyword.get(opts, :message, "Pull Request successfully merged")

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}/merge"

      if user_token do
        assert get_req_header(conn, "authorization") == ["Bearer #{user_token}"]
      end

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert decoded["merge_method"] == merge_method

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "sha" => sha,
          "merged" => true,
          "message" => message
        })
      )
    end)
  end

  def mock_merge_pull_request_error(repo, pr_number, status \\ 405, message \\ "Pull Request is not mergeable") do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}/merge"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => message}))
    end)
  end

  def mock_mark_pull_request_ready_success(repo, pr_number, opts \\ []) do
    node_id = Keyword.get(opts, :node_id, "PR_kwDO123456")
    user_token = Keyword.get(opts, :user_token)
    already_ready = Keyword.get(opts, :already_ready, false)

    # 1. Query for PR node ID and isDraft status
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"

      if user_token do
        assert get_req_header(conn, "authorization") == ["Bearer #{user_token}"]
      end

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      [owner, name] = String.split(repo, "/", parts: 2)

      assert decoded["variables"]["owner"] == owner
      assert decoded["variables"]["name"] == name
      assert decoded["variables"]["number"] == pr_number

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{
                "id" => node_id,
                "isDraft" => not already_ready
              }
            }
          }
        })
      )
    end)

    # 2. Mutation to mark ready (only called if not already ready)
    if !already_ready do
      Req.Test.expect(Rail.GitHub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/graphql"

        if user_token do
          assert get_req_header(conn, "authorization") == ["Bearer #{user_token}"]
        end

        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["variables"]["input"]["pullRequestId"] == node_id

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "markPullRequestReady" => %{
                "pullRequest" => %{
                  "id" => node_id,
                  "isDraft" => false
                }
              }
            }
          })
        )
      end)
    end
  end

  def mock_mark_pull_request_ready_pr_not_found(_repo, _pr_number) do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "repository" => %{"pullRequest" => nil}
          }
        })
      )
    end)
  end

  def mock_mark_pull_request_ready_mutation_graphql_error(_repo, _pr_number, error_message) do
    # Query succeeds with isDraft: true
    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{"id" => "PR_123", "isDraft" => true}
            }
          }
        })
      )
    end)

    # Mutation returns GraphQL error
    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "errors" => [%{"message" => error_message}]
        })
      )
    end)
  end

  def mock_mark_pull_request_ready_mutation_http_error(_repo, _pr_number, status, message) do
    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{"id" => "PR_123", "isDraft" => true}
            }
          }
        })
      )
    end)

    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => message}))
    end)
  end

  def mock_graphql_http_error(status, message) do
    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => message}))
    end)
  end

  def mock_mark_pull_request_ready_query_not_found(_repo, _pr_number) do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "repository" => nil
          }
        })
      )
    end)
  end

  def mock_mark_pull_request_ready_graphql_error(error_message \\ "GraphQL error") do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/graphql"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "errors" => [%{"message" => error_message}]
        })
      )
    end)
  end

  def mock_pull_request_number_for_branch_success(repo, branch, pr_number_or_nil, opts \\ []) do
    user_token = Keyword.get(opts, :user_token)

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls"
      query = URI.decode_query(conn.query_string)
      assert query["state"] == "all"
      assert String.contains?(query["head"], branch)

      if user_token do
        assert get_req_header(conn, "authorization") == ["Bearer #{user_token}"]
      end

      response_body =
        if pr_number_or_nil do
          [%{"number" => pr_number_or_nil, "head" => %{"ref" => branch}}]
        else
          []
        end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(response_body))
    end)
  end

  def mock_pull_request_number_for_branch_error(repo, _branch, status \\ 500) do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => "Internal Server Error"}))
    end)
  end

  def mock_delete_remote_branch_success(repo, branch, opts \\ []) do
    user_token = Keyword.get(opts, :user_token)
    clean_branch = String.replace_prefix(branch, "refs/heads/", "")

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/repos/#{repo}/git/refs/heads/#{clean_branch}"

      if user_token do
        assert get_req_header(conn, "authorization") == ["Bearer #{user_token}"]
      end

      send_resp(conn, 204, "")
    end)
  end

  def mock_delete_remote_branch_not_found(repo, branch, opts \\ []) do
    user_token = Keyword.get(opts, :user_token)
    clean_branch = String.replace_prefix(branch, "refs/heads/", "")

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/repos/#{repo}/git/refs/heads/#{clean_branch}"

      if user_token do
        assert get_req_header(conn, "authorization") == ["Bearer #{user_token}"]
      end

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{"message" => "Reference does not exist"}))
    end)
  end

  def mock_delete_remote_branch_error(repo, branch, status \\ 403, message \\ "Forbidden") do
    clean_branch = String.replace_prefix(branch, "refs/heads/", "")

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/repos/#{repo}/git/refs/heads/#{clean_branch}"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => message}))
    end)
  end

  def mock_pull_request_is_merged_success(repo, pr_number, merged \\ true, opts \\ []) do
    user_token = Keyword.get(opts, :user_token)

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}/merge"

      if user_token do
        assert get_req_header(conn, "authorization") == ["Bearer #{user_token}"]
      end

      if merged do
        send_resp(conn, 204, "")
      else
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{"message" => "Not Found"}))
      end
    end)
  end

  def mock_mark_pull_request_ready_mutation_transport_error do
    Req.Test.expect(Rail.GitHub, fn conn ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "data" => %{
            "repository" => %{
              "pullRequest" => %{"id" => "PR_123", "isDraft" => true}
            }
          }
        })
      )
    end)

    Req.Test.expect(Rail.GitHub, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)
  end

  def mock_pull_request_is_merged_error(repo, pr_number, status \\ 500) do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}/merge"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{"message" => "Server error"}))
    end)
  end

  def mock_pull_request_state_lazy_sequence(repo, pr_number) do
    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"mergeable" => nil, "draft" => true}))
    end)

    Req.Test.expect(Rail.GitHub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/repos/#{repo}/pulls/#{pr_number}"

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(%{"mergeable" => true, "draft" => nil}))
    end)
  end
end
