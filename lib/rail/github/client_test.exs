defmodule Rail.GitHub.ClientTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.GitHub

  alias Rail.GitHub.Client

  @test_fixture_pem_path "test/support/fixtures/github_app.pem"

  describe "generate_jwt/3" do
    test "generates a valid RS256 JWT using configured app_id and private_key" do
      assert {:ok, jwt} = Client.generate_jwt()

      assert byte_size(jwt) > 0
      parts = String.split(jwt, ".")
      assert length(parts) == 3

      [header_b64, payload_b64, _sig_b64] = parts
      header = Jason.decode!(Base.url_decode64!(header_b64, padding: false))
      payload = Jason.decode!(Base.url_decode64!(payload_b64, padding: false))

      assert header["alg"] == "RS256"
      assert header["typ"] == "JWT"
      assert payload["iss"] == "test_github_app_id"
      assert is_integer(payload["iat"])
      assert is_integer(payload["exp"])
      assert payload["exp"] - payload["iat"] == 660
    end

    test "allows overriding app_id, private_key and now timestamp" do
      pem = File.read!(@test_fixture_pem_path)
      now = 1_700_000_000

      assert {:ok, jwt} = Client.generate_jwt("custom_app_999", pem, now: now)

      [_h, payload_b64, _s] = String.split(jwt, ".")
      payload = Jason.decode!(Base.url_decode64!(payload_b64, padding: false))

      assert payload["iss"] == "custom_app_999"
      assert payload["iat"] == now - 60
      assert payload["exp"] == now + 600
    end

    test "loads private key from file path" do
      assert {:ok, jwt} = Client.generate_jwt("app_from_path", @test_fixture_pem_path)
      assert byte_size(jwt) > 0
    end

    test "returns error when app_id is missing or empty" do
      pem = File.read!(@test_fixture_pem_path)

      assert {:error, :missing_github_app_id} = Client.generate_jwt(nil, pem)
      assert {:error, :missing_github_app_id} = Client.generate_jwt("", pem)
    end

    test "returns error when private_key is missing or empty" do
      assert {:error, :missing_github_app_private_key} = Client.generate_jwt("app_id", nil)
      assert {:error, :missing_github_app_private_key} = Client.generate_jwt("app_id", "")
    end

    test "returns error when private_key is a nonexistent file path" do
      assert {:error, :invalid_github_app_private_key} =
               Client.generate_jwt("app_id", "nonexistent/path/to/key.pem")
    end
  end

  describe "installation_token/2 and /4" do
    test "exchanges JWT for installation access token successfully" do
      mock_installation_token_success(
        installation_id: 12_345,
        token: "ghs_installation_token_abc123"
      )

      assert {:ok, "ghs_installation_token_abc123"} = Client.installation_token(12_345)
    end

    test "accepts options with custom app_id, private_key, or explicit jwt" do
      mock_installation_token_success(
        installation_id: 54_321,
        token: "ghs_custom_token"
      )

      assert {:ok, "ghs_custom_token"} =
               Client.installation_token(54_321,
                 app_id: "override_app",
                 private_key: @test_fixture_pem_path
               )
    end

    test "accepts explicit app_id and private_key arity 3 and 4" do
      mock_installation_token_success(
        installation_id: 99_999,
        token: "ghs_arity3_token"
      )

      assert {:ok, "ghs_arity3_token"} =
               Client.installation_token("app_id", @test_fixture_pem_path, 99_999)

      mock_installation_token_success(
        installation_id: 88_888,
        token: "ghs_arity4_token"
      )

      assert {:ok, "ghs_arity4_token"} =
               Client.installation_token("app_id", @test_fixture_pem_path, 88_888, [])
    end

    test "uses explicit :jwt option when provided" do
      mock_installation_token_success(
        installation_id: 77_777,
        token: "ghs_jwt_token"
      )

      assert {:ok, "ghs_jwt_token"} =
               Client.installation_token(77_777, jwt: "precomputed_jwt")
    end

    test "returns error when JWT generation fails in installation_token" do
      assert {:error, :missing_github_app_id} =
               Client.installation_token(123, app_id: "")
    end

    test "returns error on API failure (e.g. 401 Unauthorized)" do
      mock_installation_token_error(401, "Bad credentials", installation_id: 12_345)

      assert {:error, {:github_api_error, 401, %{"message" => "Bad credentials"}}} =
               Client.installation_token(12_345)
    end

    test "returns error on network transport failure" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.installation_token(12_345)
    end
  end

  describe "list_installation_repositories/2" do
    test "returns repositories list on success" do
      repos = [
        %{"id" => 1, "name" => "repo-1", "full_name" => "org/repo-1"},
        %{"id" => 2, "name" => "repo-2", "full_name" => "org/repo-2"}
      ]

      mock_list_installation_repositories_success(repositories: repos)

      assert {:ok, ^repos} = Client.list_installation_repositories("ghs_token")
    end

    test "returns error on API failure" do
      mock_list_installation_repositories_error(401, "Requires authentication")

      assert {:error, {:github_api_error, 401, %{"message" => "Requires authentication"}}} =
               Client.list_installation_repositories("ghs_token")
    end

    test "returns error on network transport failure" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Client.list_installation_repositories("ghs_token")
    end
  end

  describe "pull_request_state/4" do
    test "returns mergeable immediately when mergeable is boolean true" do
      mock_pull_request_state_success("owner/repo", 42, mergeable: true, draft: false)

      assert {:ok, %{mergeable: :mergeable, is_draft: false}} =
               Client.pull_request_state("owner/repo", 42, "token")
    end

    test "returns conflicting immediately when mergeable is boolean false" do
      mock_pull_request_state_success("owner/repo", 42, mergeable: false, draft: true)

      assert {:ok, %{mergeable: :conflicting, is_draft: true}} =
               Client.pull_request_state("owner/repo", 42, "token")
    end

    test "handles string MERGEABLE and CONFLICTING" do
      mock_pull_request_state_success("owner/repo", 42, mergeable: "MERGEABLE", draft: false)

      assert {:ok, %{mergeable: :mergeable, is_draft: false}} =
               Client.pull_request_state("owner/repo", 42, "token")

      mock_pull_request_state_success("owner/repo", 43, mergeable: "CONFLICTING", draft: false)

      assert {:ok, %{mergeable: :conflicting, is_draft: false}} =
               Client.pull_request_state("owner/repo", 43, "token")
    end

    test "retries when mergeable is nil (:unknown) and resolves on subsequent attempt" do
      # Attempt 1: mergeable is nil
      mock_pull_request_state_success("owner/repo", 42, mergeable: nil, draft: true)
      # Attempt 2: mergeable is resolved to true
      mock_pull_request_state_success("owner/repo", 42, mergeable: true, draft: true)

      assert {:ok, %{mergeable: :mergeable, is_draft: true}} =
               Client.pull_request_state("owner/repo", 42, "token", retry_delay_ms: 0)
    end

    test "returns :unknown when attempts are exhausted" do
      mock_pull_request_state_success("owner/repo", 42, mergeable: nil, draft: true)
      mock_pull_request_state_success("owner/repo", 42, mergeable: nil, draft: true)
      mock_pull_request_state_success("owner/repo", 42, mergeable: nil, draft: true)

      assert {:ok, %{mergeable: :unknown, is_draft: true}} =
               Client.pull_request_state("owner/repo", 42, "token", attempts: 3, retry_delay_ms: 0)
    end

    test "preserves draft state when subsequent response has non-boolean draft" do
      mock_pull_request_state_lazy_sequence("owner/repo", 42)

      assert {:ok, %{mergeable: :mergeable, is_draft: true}} =
               Client.pull_request_state("owner/repo", 42, "token", retry_delay_ms: 0)
    end

    test "returns error on API failure (e.g. 404 Not Found)" do
      mock_pull_request_state_error("owner/repo", 404, 404, "Not Found")

      assert {:error, {:github_api_error, 404, %{"message" => "Not Found"}}} =
               Client.pull_request_state("owner/repo", 404, "token")
    end

    test "returns error on transport failure" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      assert {:error, %Req.TransportError{reason: :nxdomain}} =
               Client.pull_request_state("owner/repo", 42, "token")
    end
  end

  describe "merge_pull_request/4" do
    test "merges pull request with squash method and human user token" do
      mock_merge_pull_request_success("owner/repo", 10,
        user_token: "user_oauth_tok_123",
        merge_method: "squash",
        sha: "merged_sha_123",
        message: "Pull Request successfully merged"
      )

      assert {:ok, %{merged: true, sha: "merged_sha_123", message: "Pull Request successfully merged"}} =
               Client.merge_pull_request("owner/repo", 10, "user_oauth_tok_123")
    end

    test "allows customizing merge_method, commit_title, commit_message and sha" do
      mock_merge_pull_request_success("owner/repo", 11,
        user_token: "user_tok",
        merge_method: "rebase",
        sha: "head_sha_abc"
      )

      assert {:ok, %{merged: true}} =
               Client.merge_pull_request("owner/repo", 11, "user_tok",
                 merge_method: "rebase",
                 commit_title: "Custom Title",
                 commit_message: "Custom Body",
                 sha: "head_sha_abc"
               )
    end

    test "returns error when pull request is not mergeable (405)" do
      mock_merge_pull_request_error("owner/repo", 12, 405, "Pull Request is not mergeable")

      assert {:error, {:github_api_error, 405, %{"message" => "Pull Request is not mergeable"}}} =
               Client.merge_pull_request("owner/repo", 12, "user_tok")
    end

    test "returns error on transport failure" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :econnreset)
      end)

      assert {:error, %Req.TransportError{reason: :econnreset}} =
               Client.merge_pull_request("owner/repo", 10, "user_tok")
    end
  end

  describe "mark_pull_request_ready/4" do
    test "marks draft PR as ready via GraphQL query and mutation" do
      mock_mark_pull_request_ready_success("owner/repo", 55,
        user_token: "user_ready_tok",
        node_id: "PR_kwDO999",
        already_ready: false
      )

      assert {:ok, %{is_draft: false}} =
               Client.mark_pull_request_ready("owner/repo", 55, "user_ready_tok")
    end

    test "returns ok immediately when PR is already ready" do
      mock_mark_pull_request_ready_success("owner/repo", 56,
        user_token: "user_ready_tok",
        already_ready: true
      )

      assert {:ok, %{is_draft: false}} =
               Client.mark_pull_request_ready("owner/repo", 56, "user_ready_tok")
    end

    test "returns error when repository is not found" do
      mock_mark_pull_request_ready_query_not_found("owner/repo", 57)

      assert {:error, {:github_api_error, 404, "Repository not found"}} =
               Client.mark_pull_request_ready("owner/repo", 57, "user_tok")
    end

    test "returns error when pull request is not found in repository" do
      mock_mark_pull_request_ready_pr_not_found("owner/repo", 58)

      assert {:error, {:github_api_error, 404, "Pull request not found"}} =
               Client.mark_pull_request_ready("owner/repo", 58, "user_tok")
    end

    test "returns error on GraphQL error response in query" do
      mock_mark_pull_request_ready_graphql_error("Could not resolve to a Repository")

      assert {:error, {:github_graphql_error, [%{"message" => "Could not resolve to a Repository"}]}} =
               Client.mark_pull_request_ready("owner/repo", 59, "user_tok")
    end

    test "returns error on GraphQL error response in mutation" do
      mock_mark_pull_request_ready_mutation_graphql_error("owner/repo", 60, "Pull request is already ready")

      assert {:error, {:github_graphql_error, [%{"message" => "Pull request is already ready"}]}} =
               Client.mark_pull_request_ready("owner/repo", 60, "user_tok")
    end

    test "returns error on HTTP status error in query" do
      mock_graphql_http_error(500, "Internal Error")

      assert {:error, {:github_api_error, 500, %{"message" => "Internal Error"}}} =
               Client.mark_pull_request_ready("owner/repo", 61, "user_tok")
    end

    test "returns error on HTTP status error in mutation" do
      mock_mark_pull_request_ready_mutation_http_error("owner/repo", 62, 502, "Bad Gateway")

      assert {:error, {:github_api_error, 502, %{"message" => "Bad Gateway"}}} =
               Client.mark_pull_request_ready("owner/repo", 62, "user_tok")
    end

    test "returns error on transport error" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.mark_pull_request_ready("owner/repo", 63, "user_tok")
    end

    test "returns error on mutation transport error" do
      mock_mark_pull_request_ready_mutation_transport_error()

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Client.mark_pull_request_ready("owner/repo", 64, "user_tok")
    end
  end

  describe "pull_request_number_for_branch/4" do
    test "returns pull request number when PR for branch exists" do
      mock_pull_request_number_for_branch_success("owner/repo", "axis/feature-1", 77, user_token: "token_123")

      assert {:ok, 77} =
               Client.pull_request_number_for_branch("owner/repo", "axis/feature-1", "token_123")
    end

    test "handles branch that already has owner prefix" do
      mock_pull_request_number_for_branch_success("owner/repo", "owner:axis/feature-1", 78)

      assert {:ok, 78} =
               Client.pull_request_number_for_branch("owner/repo", "owner:axis/feature-1", "token")
    end

    test "returns nil when no pull request exists for branch" do
      mock_pull_request_number_for_branch_success("owner/repo", "axis/no-pr", nil)

      assert {:ok, nil} =
               Client.pull_request_number_for_branch("owner/repo", "axis/no-pr", "token")
    end

    test "returns error on API failure" do
      mock_pull_request_number_for_branch_error("owner/repo", "axis/fail", 500)

      assert {:error, {:github_api_error, 500, %{"message" => "Internal Server Error"}}} =
               Client.pull_request_number_for_branch("owner/repo", "axis/fail", "token")
    end

    test "returns error on transport failure" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :nxdomain)
      end)

      assert {:error, %Req.TransportError{reason: :nxdomain}} =
               Client.pull_request_number_for_branch("owner/repo", "axis/fail", "token")
    end
  end

  describe "delete_remote_branch/4" do
    test "deletes remote branch successfully" do
      mock_delete_remote_branch_success("owner/repo", "axis/done-feature", user_token: "user_tok")

      assert :ok = Client.delete_remote_branch("owner/repo", "axis/done-feature", "user_tok")
    end

    test "strips refs/heads/ prefix if provided" do
      mock_delete_remote_branch_success("owner/repo", "axis/done-feature")

      assert :ok =
               Client.delete_remote_branch("owner/repo", "refs/heads/axis/done-feature", "user_tok")
    end

    test "idempotently succeeds when branch does not exist (404)" do
      mock_delete_remote_branch_not_found("owner/repo", "axis/already-gone")

      assert :ok = Client.delete_remote_branch("owner/repo", "axis/already-gone", "user_tok")
    end

    test "returns error on other API failures (e.g. 403 Forbidden)" do
      mock_delete_remote_branch_error("owner/repo", "protected-branch", 403, "Protected branch")

      assert {:error, {:github_api_error, 403, %{"message" => "Protected branch"}}} =
               Client.delete_remote_branch("owner/repo", "protected-branch", "user_tok")
    end

    test "returns error on transport failure" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Client.delete_remote_branch("owner/repo", "axis/fail", "user_tok")
    end
  end

  describe "pull_request_is_merged/4" do
    test "returns true when PR is merged (204 No Content)" do
      mock_pull_request_is_merged_success("owner/repo", 100, true, user_token: "tok")

      assert {:ok, true} = Client.pull_request_is_merged("owner/repo", 100, "tok")
    end

    test "returns false when PR is not merged (404 Not Found)" do
      mock_pull_request_is_merged_success("owner/repo", 101, false, user_token: "tok")

      assert {:ok, false} = Client.pull_request_is_merged("owner/repo", 101, "tok")
    end

    test "returns error on unexpected status" do
      mock_pull_request_is_merged_error("owner/repo", 102, 500)

      assert {:error, {:github_api_error, 500, %{"message" => "Server error"}}} =
               Client.pull_request_is_merged("owner/repo", 102, "tok")
    end

    test "returns error on transport failure" do
      Req.Test.expect(Rail.GitHub, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Client.pull_request_is_merged("owner/repo", 100, "tok")
    end
  end

  describe "parse_repo fallback" do
    test "handles repo without slash" do
      mock_pull_request_state_success("simplerepo/simplerepo", 1, mergeable: true)

      assert {:ok, %{mergeable: :mergeable}} =
               Client.pull_request_state("simplerepo", 1, "token")
    end
  end
end
