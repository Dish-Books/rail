defmodule Rail.GitHub.Client do
  @moduledoc """
  HTTP and GraphQL client for GitHub App installation tokens,
  pull request state polling, and user-attributed pull request operations.
  """

  @default_api_url "https://api.github.com"
  @default_api_version "2022-11-28"
  @default_accept "application/vnd.github+json"

  def config do
    Application.get_env(:rail, :github, [])
  end

  def generate_jwt(app_id \\ :default, private_key \\ :default, opts \\ []) do
    cfg = config()
    app_id = if app_id == :default, do: cfg[:app_id], else: app_id
    private_key_input = if private_key == :default, do: cfg[:private_key], else: private_key

    with {:ok, resolved_app_id} <- validate_app_id(app_id),
         {:ok, pem} <- load_private_key(private_key_input) do
      now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

      claims = %{
        "iat" => now - 60,
        "exp" => now + 600,
        "iss" => to_string(resolved_app_id)
      }

      jwk = JOSE.JWK.from_pem(pem)
      header = %{"alg" => "RS256", "typ" => "JWT"}
      {_jws, token} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()

      {:ok, token}
    end
  end

  def installation_token(installation_id, opts \\ []) when is_list(opts) do
    cfg = config()
    app_id = Keyword.get(opts, :app_id, cfg[:app_id])
    private_key = Keyword.get(opts, :private_key, cfg[:private_key])
    installation_token(app_id, private_key, installation_id, opts)
  end

  def installation_token(app_id, private_key, installation_id) do
    installation_token(app_id, private_key, installation_id, [])
  end

  def installation_token(app_id, private_key, installation_id, opts) do
    with {:ok, jwt} <- resolve_jwt(app_id, private_key, opts) do
      req = build_req(opts)
      path = "/app/installations/#{installation_id}/access_tokens"

      case Req.post(req,
             url: path,
             auth: {:bearer, jwt},
             headers: default_headers()
           ) do
        {:ok, %{status: status, body: %{"token" => token}}} when status in [200, 201] ->
          {:ok, token}

        {:ok, %{status: status, body: body}} ->
          {:error, {:github_api_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def list_installation_repositories(installation_token, opts \\ []) do
    req = build_req(opts)
    path = "/installation/repositories"

    case Req.get(req,
           url: path,
           auth: {:bearer, installation_token},
           headers: default_headers()
         ) do
      {:ok, %{status: 200, body: %{"repositories" => repositories}}} ->
        {:ok, repositories}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def pull_request_state(repo, pr_number, token, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, 3)
    retry_delay_ms = Keyword.get(opts, :retry_delay_ms, 2000)

    poll_pull_request_state(repo, pr_number, token, attempts, retry_delay_ms, false, opts)
  end

  def merge_pull_request(repo, pr_number, user_token, opts \\ []) do
    slug = repo_slug(repo)
    req = build_req(opts)
    path = "/repos/#{slug}/pulls/#{pr_number}/merge"
    merge_method = Keyword.get(opts, :merge_method, "squash")

    body =
      %{merge_method: merge_method}
      |> maybe_put(:commit_title, Keyword.get(opts, :commit_title))
      |> maybe_put(:commit_message, Keyword.get(opts, :commit_message))
      |> maybe_put(:sha, Keyword.get(opts, :sha))

    case Req.put(req,
           url: path,
           auth: {:bearer, user_token},
           headers: default_headers(),
           json: body
         ) do
      {:ok, %{status: 200, body: %{"sha" => sha} = resp_body}} ->
        {:ok,
         %{
           merged: true,
           sha: sha,
           message: resp_body["message"]
         }}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:github_api_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def mark_pull_request_ready(repo, pr_number, user_token, opts \\ []) do
    [owner, name] = parse_repo(repo)
    req = build_req(opts)

    with {:ok, node_id, is_draft} <- fetch_pr_node_id(req, owner, name, pr_number, user_token) do
      if is_draft do
        execute_mark_ready_mutation(req, node_id, user_token)
      else
        {:ok, %{is_draft: false}}
      end
    end
  end

  def pull_request_number_for_branch(repo, branch, token, opts \\ []) do
    [owner, _name] = parse_repo(repo)
    slug = repo_slug(repo)
    req = build_req(opts)
    path = "/repos/#{slug}/pulls"

    head_filter =
      if String.contains?(branch, ":") do
        branch
      else
        "#{owner}:#{branch}"
      end

    case Req.get(req,
           url: path,
           auth: {:bearer, token},
           headers: default_headers(),
           params: [state: "all", head: head_filter]
         ) do
      {:ok, %{status: 200, body: [%{"number" => number} | _rest]}} ->
        {:ok, number}

      {:ok, %{status: 200, body: []}} ->
        {:ok, nil}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_remote_branch(repo, branch, user_token, opts \\ []) do
    slug = repo_slug(repo)
    clean_branch = String.replace_prefix(branch, "refs/heads/", "")
    req = build_req(opts)
    path = "/repos/#{slug}/git/refs/heads/#{clean_branch}"

    case Req.delete(req,
           url: path,
           auth: {:bearer, user_token},
           headers: default_headers()
         ) do
      {:ok, %{status: 204}} ->
        :ok

      {:ok, %{status: 404}} ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def pull_request_is_merged(repo, pr_number, token, opts \\ []) do
    slug = repo_slug(repo)
    req = build_req(opts)
    path = "/repos/#{slug}/pulls/#{pr_number}/merge"

    case Req.get(req,
           url: path,
           auth: {:bearer, token},
           headers: default_headers()
         ) do
      {:ok, %{status: 204}} ->
        {:ok, true}

      {:ok, %{status: 404}} ->
        {:ok, false}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp poll_pull_request_state(repo, pr_number, token, attempts_left, retry_delay_ms, known_draft, opts) do
    slug = repo_slug(repo)
    req = build_req(opts)
    path = "/repos/#{slug}/pulls/#{pr_number}"

    case Req.get(req,
           url: path,
           auth: {:bearer, token},
           headers: default_headers()
         ) do
      {:ok, %{status: 200, body: body}} ->
        mergeable = parse_mergeable(body["mergeable"])
        is_draft = parse_draft(body, known_draft)

        if mergeable != :unknown or attempts_left <= 1 do
          {:ok, %{mergeable: mergeable, is_draft: is_draft}}
        else
          if retry_delay_ms > 0, do: Process.sleep(retry_delay_ms)
          poll_pull_request_state(repo, pr_number, token, attempts_left - 1, retry_delay_ms, is_draft, opts)
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_pr_node_id(req, owner, name, pr_number, user_token) do
    query = """
    query GetPullRequestId($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          id
          isDraft
        }
      }
    }
    """

    variables = %{
      "owner" => owner,
      "name" => name,
      "number" => pr_number
    }

    case Req.post(req,
           url: "/graphql",
           auth: {:bearer, user_token},
           headers: default_headers(),
           json: %{query: query, variables: variables}
         ) do
      {:ok,
       %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => %{"id" => id, "isDraft" => is_draft}}}}}} ->
        {:ok, id, is_draft}

      {:ok, %{status: 200, body: %{"data" => %{"repository" => nil}}}} ->
        {:error, {:github_api_error, 404, "Repository not found"}}

      {:ok, %{status: 200, body: %{"data" => %{"repository" => %{"pullRequest" => nil}}}}} ->
        {:error, {:github_api_error, 404, "Pull request not found"}}

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        {:error, {:github_graphql_error, errors}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_mark_ready_mutation(req, node_id, user_token) do
    mutation = """
    mutation MarkPullRequestReady($input: MarkPullRequestReadyInput!) {
      markPullRequestReady(input: $input) {
        pullRequest {
          id
          isDraft
        }
      }
    }
    """

    variables = %{
      "input" => %{
        "pullRequestId" => node_id
      }
    }

    case Req.post(req,
           url: "/graphql",
           auth: {:bearer, user_token},
           headers: default_headers(),
           json: %{query: mutation, variables: variables}
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"markPullRequestReady" => %{"pullRequest" => %{"isDraft" => is_draft}}}}}} ->
        {:ok, %{is_draft: is_draft}}

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        {:error, {:github_graphql_error, errors}}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_jwt(app_id, private_key, opts) do
    case Keyword.get(opts, :jwt) do
      jwt when is_binary(jwt) -> {:ok, jwt}
      _other -> generate_jwt(app_id, private_key, opts)
    end
  end

  defp validate_app_id(nil), do: {:error, :missing_github_app_id}
  defp validate_app_id(""), do: {:error, :missing_github_app_id}
  defp validate_app_id(app_id), do: {:ok, app_id}

  defp load_private_key(nil), do: {:error, :missing_github_app_private_key}
  defp load_private_key(""), do: {:error, :missing_github_app_private_key}

  defp load_private_key(key) when is_binary(key) do
    if String.contains?(key, "-----BEGIN") do
      {:ok, key}
    else
      if File.exists?(key) do
        {:ok, File.read!(key)}
      else
        {:error, :invalid_github_app_private_key}
      end
    end
  end

  defp parse_mergeable(true), do: :mergeable
  defp parse_mergeable("MERGEABLE"), do: :mergeable
  defp parse_mergeable(false), do: :conflicting
  defp parse_mergeable("CONFLICTING"), do: :conflicting
  defp parse_mergeable(_other), do: :unknown

  defp parse_draft(body, fallback) do
    cond do
      is_boolean(body["draft"]) -> body["draft"]
      is_boolean(body["isDraft"]) -> body["isDraft"]
      true -> fallback
    end
  end

  defp parse_repo(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] -> [owner, name]
      [name] -> [name, name]
    end
  end

  defp repo_slug(repo) do
    [owner, name] = parse_repo(repo)
    "#{owner}/#{name}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_headers do
    [
      {"accept", @default_accept},
      {"x-github-api-version", @default_api_version}
    ]
  end

  defp build_req(opts) do
    cfg = config()
    req_options = Keyword.get(cfg, :req_options, [])
    custom_opts = Keyword.get(opts, :req_options, [])

    [base_url: @default_api_url, retry: false]
    |> Req.new()
    |> Req.merge(req_options)
    |> Req.merge(custom_opts)
  end
end
