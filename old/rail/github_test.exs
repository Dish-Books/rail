defmodule Rail.GitHubTest do
  use Rail.DataCase, async: true

  import RailTest.Mocks.GitHub

  alias Rail.GitHub

  @test_fixture_pem_path "test/support/fixtures/github_app.pem"

  describe "Rail.GitHub delegations" do
    test "delegates generate_jwt" do
      assert {:ok, jwt} = GitHub.generate_jwt()
      assert byte_size(jwt) > 0

      pem = File.read!(@test_fixture_pem_path)
      assert {:ok, jwt_custom} = GitHub.generate_jwt("app_id", pem, now: 1_700_000_000)
      assert byte_size(jwt_custom) > 0
    end

    test "delegates installation_token" do
      mock_installation_token_success(installation_id: 111, token: "tok_111")
      assert {:ok, "tok_111"} = GitHub.installation_token(111)

      mock_installation_token_success(installation_id: 222, token: "tok_222")
      assert {:ok, "tok_222"} = GitHub.installation_token(222, app_id: "override")

      mock_installation_token_success(installation_id: 333, token: "tok_333")
      assert {:ok, "tok_333"} = GitHub.installation_token("app_id", @test_fixture_pem_path, 333)

      mock_installation_token_success(installation_id: 444, token: "tok_444")
      assert {:ok, "tok_444"} = GitHub.installation_token("app_id", @test_fixture_pem_path, 444, [])
    end

    test "delegates list_installation_repositories" do
      mock_list_installation_repositories_success(repositories: [%{"id" => 1}])
      assert {:ok, [%{"id" => 1}]} = GitHub.list_installation_repositories("tok")
    end

    test "delegates pull_request_state" do
      mock_pull_request_state_success("owner/repo", 1, mergeable: true)
      assert {:ok, %{mergeable: :mergeable}} = GitHub.pull_request_state("owner/repo", 1, "tok")
    end

    test "delegates merge_pull_request" do
      mock_merge_pull_request_success("owner/repo", 2, user_token: "usr_tok")
      assert {:ok, %{merged: true}} = GitHub.merge_pull_request("owner/repo", 2, "usr_tok")
    end

    test "delegates mark_pull_request_ready" do
      mock_mark_pull_request_ready_success("owner/repo", 3, already_ready: true)
      assert {:ok, %{is_draft: false}} = GitHub.mark_pull_request_ready("owner/repo", 3, "usr_tok")
    end

    test "delegates pull_request_number_for_branch" do
      mock_pull_request_number_for_branch_success("owner/repo", "feat", 4)
      assert {:ok, 4} = GitHub.pull_request_number_for_branch("owner/repo", "feat", "tok")
    end

    test "delegates delete_remote_branch" do
      mock_delete_remote_branch_success("owner/repo", "feat")
      assert :ok = GitHub.delete_remote_branch("owner/repo", "feat", "usr_tok")
    end

    test "delegates pull_request_is_merged" do
      mock_pull_request_is_merged_success("owner/repo", 5, true)
      assert {:ok, true} = GitHub.pull_request_is_merged("owner/repo", 5, "tok")
    end
  end
end
