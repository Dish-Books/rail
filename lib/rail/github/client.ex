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

  @doc "Changes a pull request in `repo`, from the attrs GitHub takes, such as `body`."
  def update_pull_request(token, repo, number, attrs, opts \\ []) do
    opts
    |> build_req()
    |> Req.patch(url: "/repos/#{repo}/pulls/#{number}", auth: {:bearer, token}, headers: headers(), json: attrs)
    |> case do
      {:ok, %{status: 200, body: %{"number" => _number} = pull_request}} -> {:ok, pull_request}
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

  @doc """
  One page of pull requests in `repo`, filtered by GitHub's own params, such as
  `state`, `sort`, `direction`, `per_page` and `page`.
  """
  def list_pull_requests(token, repo, params, opts \\ []) do
    opts
    |> build_req()
    |> Req.get(url: "/repos/#{repo}/pulls", params: params, auth: {:bearer, token}, headers: headers())
    |> case do
      {:ok, %{status: 200, body: pull_requests}} when is_list(pull_requests) -> {:ok, pull_requests}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Every inline review comment on a pull request, across all pages."
  def list_review_comments(token, repo, number, opts \\ []) do
    paginate(token, "/repos/#{repo}/pulls/#{number}/comments", opts)
  end

  @doc "Every review submitted on a pull request, with its body, across all pages."
  def list_reviews(token, repo, number, opts \\ []) do
    paginate(token, "/repos/#{repo}/pulls/#{number}/reviews", opts)
  end

  @doc "Compares `base` with `head` in `repo`: the commits between them and each file's patch."
  def compare_commits(token, repo, base, head, opts \\ []) do
    opts
    |> build_req()
    |> Req.get(url: "/repos/#{repo}/compare/#{base}...#{head}", auth: {:bearer, token}, headers: headers())
    |> case do
      {:ok, %{status: 200, body: %{"files" => _files} = comparison}} -> {:ok, comparison}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Opens an issue in `repo` from the attrs GitHub takes: `title`, `body`, `labels` and `assignees`.
  """
  def create_issue(token, repo, attrs, opts \\ []) do
    opts
    |> build_req()
    |> Req.post(url: "/repos/#{repo}/issues", auth: {:bearer, token}, headers: headers(), json: attrs)
    |> issues_result(201)
  end

  @doc """
  Fetches issue `number` in `repo`, labels and assignees included.
  """
  def get_issue(token, repo, number, opts \\ []) do
    opts
    |> build_req()
    |> Req.get(url: "/repos/#{repo}/issues/#{number}", auth: {:bearer, token}, headers: headers())
    |> issues_result(200)
  end

  @doc """
  Edits issue `number`. Never pass `labels` or `assignees`: each replaces the whole list.
  """
  def update_issue(token, repo, number, attrs, opts \\ []) do
    opts
    |> build_req()
    |> Req.patch(url: "/repos/#{repo}/issues/#{number}", auth: {:bearer, token}, headers: headers(), json: attrs)
    |> issues_result(200)
  end

  @doc """
  One page of `repo`'s issues, as `params` (`state`, `since`, `page`, ...) select them. Pull requests come too.
  """
  def list_issues(token, repo, params, opts \\ []) do
    opts
    |> build_req()
    |> Req.get(
      url: "/repos/#{repo}/issues",
      params: Keyword.merge([sort: "updated", direction: "asc", per_page: 100], params),
      auth: {:bearer, token},
      headers: headers()
    )
    |> issues_result(200)
  end

  @doc """
  Adds the logins to issue `number`'s assignees, leaving the others.
  """
  def add_assignees(token, repo, number, logins, opts \\ []) do
    opts
    |> build_req()
    |> Req.post(
      url: "/repos/#{repo}/issues/#{number}/assignees",
      auth: {:bearer, token},
      headers: headers(),
      json: %{assignees: logins}
    )
    |> issues_result(201)
  end

  @doc """
  Removes the logins from issue `number`'s assignees, leaving the others.
  """
  def remove_assignees(token, repo, number, logins, opts \\ []) do
    opts
    |> build_req()
    |> Req.delete(
      url: "/repos/#{repo}/issues/#{number}/assignees",
      auth: {:bearer, token},
      headers: headers(),
      json: %{assignees: logins}
    )
    |> issues_result(200)
  end

  @doc """
  Adds labels to issue `number`, leaving the ones it has.
  """
  def add_labels(token, repo, number, names, opts \\ []) do
    opts
    |> build_req()
    |> Req.post(
      url: "/repos/#{repo}/issues/#{number}/labels",
      auth: {:bearer, token},
      headers: headers(),
      json: %{labels: names}
    )
    |> issues_result(200)
  end

  @doc """
  Takes label `name` off issue `number`. One it does not have is already off.
  """
  def remove_label(token, repo, number, name, opts \\ []) do
    opts
    |> build_req()
    |> Req.delete(
      url: "/repos/#{repo}/issues/#{number}/labels/#{URI.encode(name, &URI.char_unreserved?/1)}",
      auth: {:bearer, token},
      headers: headers()
    )
    |> case do
      {:ok, %{status: 404}} -> {:ok, []}
      result -> issues_result(result, 200)
    end
  end

  @doc """
  Makes a label in `repo` from `name`, `color` and `description`. One that already exists is left as it is.
  """
  def create_label(token, repo, attrs, opts \\ []) do
    opts
    |> build_req()
    |> Req.post(url: "/repos/#{repo}/labels", auth: {:bearer, token}, headers: headers(), json: attrs)
    |> case do
      {:ok, %{status: 422, body: %{"errors" => [%{"code" => "already_exists"} | _rest]}}} -> {:ok, :already_exists}
      result -> issues_result(result, 201)
    end
  end

  @doc """
  Comments on issue `number`.
  """
  def create_issue_comment(token, repo, number, body, opts \\ []) do
    opts
    |> build_req()
    |> Req.post(
      url: "/repos/#{repo}/issues/#{number}/comments",
      auth: {:bearer, token},
      headers: headers(),
      json: %{body: body}
    )
    |> issues_result(201)
  end

  @doc """
  One page of the comments on every issue and pull request in `repo`, oldest change first.
  """
  def list_repo_issue_comments(token, repo, params, opts \\ []) do
    opts
    |> build_req()
    |> Req.get(
      url: "/repos/#{repo}/issues/comments",
      params: Keyword.merge([sort: "updated", direction: "asc", per_page: 100], params),
      auth: {:bearer, token},
      headers: headers()
    )
    |> issues_result(200)
  end

  defp paginate(token, url, opts, page \\ 1, acc \\ []) do
    opts
    |> build_req()
    |> Req.get(url: url, params: [per_page: 100, page: page], auth: {:bearer, token}, headers: headers())
    |> case do
      {:ok, %{status: 200, body: items}} when length(items) == 100 -> paginate(token, url, opts, page + 1, acc ++ items)
      {:ok, %{status: 200, body: items}} when is_list(items) -> {:ok, acc ++ items}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # An App never granted Issues, and a repository with Issues turned off, each need a person to act.
  defp issues_result({:ok, %{status: status, body: body}}, status), do: {:ok, body}

  defp issues_result({:ok, %{status: 403, body: %{"message" => "Resource not accessible by integration"}}}, _expected),
    do: {:error, :github_issues_permission_missing}

  defp issues_result({:ok, %{status: 410}}, _expected), do: {:error, :github_issues_disabled}
  defp issues_result({:ok, %{status: status, body: body}}, _expected), do: {:error, {:github_api_error, status, body}}
  defp issues_result({:error, reason}, _expected), do: {:error, reason}

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
