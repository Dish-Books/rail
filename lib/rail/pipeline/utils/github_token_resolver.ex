defmodule Rail.Pipeline.Utils.GitHubTokenResolver do
  @moduledoc false

  alias Rail.GitHub
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  Resolves a GitHub bearer token for performing GitHub operations.
  Priority:
  1. Explicit token in `opts[:token]` or `opts[:github_token]`.
  2. Acting user's GitHub token if present on user or scope.
  3. Installation token for the project's `github_installation_id`.
  """
  def resolve_github_token(scope_or_user, project, opts \\ []) do
    case Keyword.get(opts, :token) || Keyword.get(opts, :github_token) do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _unspecified ->
        case extract_user_github_token(scope_or_user) do
          {:ok, token} ->
            {:ok, token}

          :error ->
            resolve_installation_token(project, opts)
        end
    end
  end

  defp extract_user_github_token(%User{github_token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp extract_user_github_token(%Scope{user: %User{github_token: token}}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp extract_user_github_token(uid) when is_binary(uid) do
    case Repo.get(User, uid) do
      %User{github_token: token} when is_binary(token) and token != "" -> {:ok, token}
      _other -> :error
    end
  end

  defp extract_user_github_token(_other), do: :error

  defp resolve_installation_token(%Project{github_installation_id: inst_id}, opts)
       when is_integer(inst_id) or is_binary(inst_id) do
    GitHub.installation_token(inst_id, opts)
  end

  defp resolve_installation_token(_project, _opts) do
    {:error, :missing_github_token}
  end
end
