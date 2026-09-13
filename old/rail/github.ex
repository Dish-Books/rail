defmodule Rail.GitHub do
  @moduledoc false

  alias Rail.GitHub.Client

  defdelegate generate_jwt(app_id \\ :default, private_key \\ :default, opts \\ []), to: Client
  defdelegate installation_token(installation_id, opts \\ []), to: Client
  defdelegate installation_token(app_id, private_key, installation_id), to: Client
  defdelegate installation_token(app_id, private_key, installation_id, opts), to: Client
  defdelegate list_installation_repositories(installation_token, opts \\ []), to: Client
  defdelegate pull_request_state(repo, pr_number, token, opts \\ []), to: Client
  defdelegate merge_pull_request(repo, pr_number, user_token, opts \\ []), to: Client
  defdelegate mark_pull_request_ready(repo, pr_number, user_token, opts \\ []), to: Client
  defdelegate pull_request_number_for_branch(repo, branch, token, opts \\ []), to: Client
  defdelegate delete_remote_branch(repo, branch, user_token, opts \\ []), to: Client
  defdelegate pull_request_is_merged(repo, pr_number, token, opts \\ []), to: Client
end
