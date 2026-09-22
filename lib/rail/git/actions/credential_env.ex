defmodule Rail.Git.Actions.CredentialEnv do
  @moduledoc false

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Projects.Schemas.Project

  @helper ~S|!f() { echo username=x-access-token; echo "password=$RAIL_GIT_TOKEN"; }; f|

  @doc """
  Mints a token from `project`'s GitHub App installation and returns the
  environment that has git push with it.

  The token reaches git through a credential helper in the environment and never
  through argv, where `ps` would show it. Returns `{:ok, env}` or GitHub's error.
  """
  def credential_env(%Project{github_installation_id: installation_id}) do
    with {:ok, token} <- GitHub.installation_token(installation_id) do
      {:ok,
       %{
         "RAIL_GIT_TOKEN" => token,
         "GIT_CONFIG_COUNT" => "1",
         "GIT_CONFIG_KEY_0" => "credential.helper",
         "GIT_CONFIG_VALUE_0" => @helper,
         "GIT_TERMINAL_PROMPT" => "0"
       }}
    end
  end
end
