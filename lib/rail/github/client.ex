defmodule Rail.GitHub.Client do
  @moduledoc """
  The one client for GitHub: the App's own credentials, and the keys a user signs
  commits with.

  There is no GitHub context around this. GitHub is not a thing Rail has business
  rules about — it is an API two actions call — so they call this directly, the
  way they call `Rail.Linear.Client`.

  It makes the call and hands back what GitHub said. The App authenticates as
  itself with a short-lived RS256 JWT and trades that for an installation token
  Rail can push with; a signing key belongs to a person and goes out with their
  own OAuth token.
  """

  @api_url "https://api.github.com"
  @api_version "2022-11-28"
  @accept "application/vnd.github+json"

  def config, do: Application.get_env(:rail, :github, [])

  @doc """
  Mints the App's JWT, good for ten minutes.

  Backdated a minute because GitHub rejects a token issued in its own future,
  and clocks drift.
  """
  def generate_jwt(opts \\ []) do
    with {:ok, app_id} <- app_id(),
         {:ok, pem} <- private_key() do
      now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
      claims = %{"iat" => now - 60, "exp" => now + 600, "iss" => to_string(app_id)}

      {_jws, token} =
        pem
        |> JOSE.JWK.from_pem()
        |> JOSE.JWT.sign(%{"alg" => "RS256", "typ" => "JWT"}, claims)
        |> JOSE.JWS.compact()

      {:ok, token}
    end
  end

  @doc """
  Trades the App's JWT for a token scoped to one installation.

  The token lasts an hour, so it is fetched per use rather than stored.
  """
  def installation_token(installation_id, opts \\ []) do
    with {:ok, jwt} <- generate_jwt(opts) do
      opts
      |> build_req()
      |> Req.post(
        url: "/app/installations/#{installation_id}/access_tokens",
        auth: {:bearer, jwt},
        headers: headers()
      )
      |> case do
        {:ok, %{status: status, body: %{"token" => token}}} when status in [200, 201] -> {:ok, token}
        {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Registers `public_key` as a signing key on the token holder's account.

  A 403 is the token missing the `write:ssh_signing_key` scope, which is what a
  user who has not signed in since the scope was added will hit.
  """
  def create_signing_key(user_token, title, public_key, opts \\ []) do
    opts
    |> build_req()
    |> Req.post(
      url: "/user/ssh_signing_keys",
      auth: {:bearer, user_token},
      headers: headers(),
      json: %{title: title, key: public_key}
    )
    |> case do
      {:ok, %{status: status, body: %{"id" => id}}} when status in [200, 201] -> {:ok, id}
      {:ok, %{status: 403, body: _body}} -> {:error, :missing_scope}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a signing key. A key GitHub no longer has is already what was wanted.
  """
  def delete_signing_key(user_token, key_id, opts \\ []) do
    opts
    |> build_req()
    |> Req.delete(url: "/user/ssh_signing_keys/#{key_id}", auth: {:bearer, user_token}, headers: headers())
    |> case do
      {:ok, %{status: status}} when status in [204, 404] -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Finds the open pull request from `branch` in `repo` (`owner/name`), or nil.
  """
  def find_pull_request(token, repo, branch, opts \\ []) do
    [owner, _name] = String.split(repo, "/", parts: 2)

    opts
    |> build_req()
    |> Req.get(
      url: "/repos/#{repo}/pulls",
      params: [head: "#{owner}:#{branch}", state: "open"],
      auth: {:bearer, token},
      headers: headers()
    )
    |> case do
      {:ok, %{status: 200, body: [pull_request | _rest]}} -> {:ok, pull_request}
      {:ok, %{status: 200, body: []}} -> {:ok, nil}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Opens a pull request in `repo` from the attrs GitHub takes: `title`, `head`,
  `base`, `body` and `draft`.
  """
  def create_pull_request(token, repo, attrs, opts \\ []) do
    opts
    |> build_req()
    |> Req.post(url: "/repos/#{repo}/pulls", auth: {:bearer, token}, headers: headers(), json: attrs)
    |> case do
      {:ok, %{status: 201, body: %{"number" => _number} = pull_request}} -> {:ok, pull_request}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Takes a draft pull request out of draft. REST cannot, so this is GraphQL, by
  the pull request's node id.
  """
  def mark_pull_request_ready(token, node_id, opts \\ []) do
    query = """
    mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }
    """

    opts
    |> build_req()
    |> Req.post(url: "/graphql", auth: {:bearer, token}, json: %{query: query, variables: %{id: node_id}})
    |> case do
      {:ok, %{status: 200, body: %{"data" => %{"markPullRequestReadyForReview" => %{}}}}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Reads one pull request in `repo` by its number."
  def get_pull_request(token, repo, number, opts \\ []) do
    opts
    |> build_req()
    |> Req.get(url: "/repos/#{repo}/pulls/#{number}", auth: {:bearer, token}, headers: headers())
    |> case do
      {:ok, %{status: 200, body: %{"number" => _number} = pull_request}} -> {:ok, pull_request}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp app_id do
    case config()[:app_id] do
      id when is_binary(id) and id != "" -> {:ok, id}
      id when is_integer(id) -> {:ok, id}
      _unset -> {:error, :missing_github_app_id}
    end
  end

  # The key is configured either as the PEM itself or as a path to it, because
  # one deployment mounts a file and another sets an environment variable.
  defp private_key do
    case config()[:private_key] do
      key when is_binary(key) and key != "" ->
        cond do
          String.contains?(key, "-----BEGIN") -> {:ok, key}
          File.exists?(key) -> {:ok, File.read!(key)}
          true -> {:error, :invalid_github_app_private_key}
        end

      _unset ->
        {:error, :missing_github_app_private_key}
    end
  end

  defp headers do
    [{"accept", @accept}, {"x-github-api-version", @api_version}]
  end

  defp build_req(opts) do
    [base_url: @api_url, retry: false]
    |> Req.new()
    |> Req.merge(Keyword.get(config(), :req_options, []))
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end
end
