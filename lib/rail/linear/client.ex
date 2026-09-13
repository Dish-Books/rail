defmodule Rail.Linear.Client do
  @moduledoc """
  The one client for Linear: OAuth, and GraphQL for issues, comments and uploads.

  It makes the call and hands back what Linear said, as Linear said it: GraphQL
  calls return the response's `data`, OAuth calls the token response body.
  Shaping any of that into Rail's terms is the caller's job.

  Every API call names the project it acts for and picks its own token. A write
  that belongs to a person passes `as:` their scope and goes out as
  them, so Linear shows their name on it; everything else — and anything by a
  user who never linked Linear — goes out as the workspace.
  """

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users

  require Logger

  @default_authorize_url "https://linear.app/oauth/authorize"
  @default_token_url "https://api.linear.app/oauth/token"
  @graphql_url "https://api.linear.app/graphql"
  @default_scope "read,write,issues:create,comments:create"
  @page_size 100

  @issue_fields """
  id
  identifier
  title
  description
  priority
  estimate
  assignee {
    id
  }
  state {
    id
    name
    type
  }
  branchName
  url
  """

  def config do
    Application.get_env(:rail, :linear, Application.get_env(:rail, :linear_oauth, []))
  end

  def authorize_url(opts \\ []) do
    cfg = oauth_config()

    params =
      [
        {"response_type", "code"},
        {"client_id", Keyword.get(opts, :client_id, cfg[:client_id])},
        {"redirect_uri", redirect_uri()},
        {"actor", "user"},
        {"scope", Keyword.get(opts, :scope, @default_scope)}
      ]

    params = if state = opts[:state], do: [{"state", state} | params], else: params

    @default_authorize_url <> "?" <> URI.encode_query(params)
  end

  def exchange_code(code, opts \\ []) do
    cfg = oauth_config()

    form = [
      grant_type: "authorization_code",
      code: code,
      client_id: Keyword.get(opts, :client_id, cfg[:client_id]),
      client_secret: Keyword.get(opts, :client_secret, cfg[:client_secret]),
      redirect_uri: redirect_uri()
    ]

    case Req.post(build_req(opts), url: @default_token_url, form: form) do
      {:ok, %{status: 200, body: %{"access_token" => _token} = body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:linear_oauth_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def refresh_token(refresh_token, opts \\ []) do
    cfg = oauth_config()

    form = [
      grant_type: "refresh_token",
      refresh_token: refresh_token,
      client_id: Keyword.get(opts, :client_id, cfg[:client_id]),
      client_secret: Keyword.get(opts, :client_secret, cfg[:client_secret])
    ]

    case Req.post(build_req(opts), url: @default_token_url, form: form) do
      {:ok, %{status: 200, body: %{"access_token" => _token} = body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:linear_token_refresh_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def viewer(token, opts \\ []) do
    query = """
    query Viewer {
      viewer {
        id
        name
        email
      }
    }
    """

    execute_query(token, query, %{}, opts)
  end

  @doc """
  Fetches one page of the issues on the project's team, found by its key. Pass
  `after:` the previous page's `pageInfo.endCursor` to continue.
  """
  def issues(%Project{} = project, opts \\ []) do
    query = """
    query Issues($teamKey: String!, $first: Int!, $after: String) {
      issues(first: $first, after: $after, filter: {team: {key: {eq: $teamKey}}}) {
        nodes {
          #{@issue_fields}
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """

    variables = %{"teamKey" => project.linear_team_key, "first" => @page_size, "after" => opts[:after]}

    with {:ok, token} <- token(project, opts) do
      execute_query(token, query, variables, opts)
    end
  end

  @doc """
  Finds the project's team by its key, with its workflow states.
  """
  def team(%Project{} = project, opts \\ []) do
    query = """
    query Team($teamKey: String!) {
      teams(first: 1, filter: {key: {eq: $teamKey}}) {
        nodes {
          id
          states {
            nodes {
              id
              type
              position
            }
          }
        }
      }
    }
    """

    with {:ok, token} <- token(project, opts) do
      execute_query(token, query, %{"teamKey" => project.linear_team_key}, opts)
    end
  end

  @doc """
  Opens a ticket. `input` is Linear's `IssueCreateInput`, team included.
  """
  def create_issue(%Project{} = project, %{} = input, opts \\ []) do
    query = """
    mutation IssueCreate($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        success
        issue {
          #{@issue_fields}
        }
      }
    }
    """

    with {:ok, token} <- token(project, opts) do
      execute_query(token, query, %{"input" => input}, opts)
    end
  end

  @doc """
  Updates a ticket. `input` is Linear's `IssueUpdateInput`.
  """
  def update_issue(%Project{} = project, issue_id, %{} = input, opts \\ []) do
    query = """
    mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) {
        success
      }
    }
    """

    with {:ok, token} <- token(project, opts) do
      execute_query(token, query, %{"id" => issue_id, "input" => input}, opts)
    end
  end

  @doc """
  Asks Linear where a file goes and puts it there, returning the `fileUpload`
  data the upload was made from.
  """
  def file_upload(target, filename, content_type, data_binary, opts \\ []) do
    query = """
    mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
      fileUpload(filename: $filename, contentType: $contentType, size: $size) {
        success
        uploadFile {
          uploadUrl
          assetUrl
          headers {
            key
            value
          }
        }
      }
    }
    """

    variables = %{"filename" => filename, "contentType" => content_type, "size" => byte_size(data_binary)}

    with {:ok, token} <- token(target, opts),
         {:ok, %{"fileUpload" => %{"success" => true, "uploadFile" => upload_file}} = data} <-
           execute_query(token, query, variables, opts),
         :ok <- put_file(upload_file, data_binary, opts) do
      {:ok, data}
    end
  end

  @doc """
  Comments on a ticket. `input` is Linear's `CommentCreateInput`.
  """
  def create_comment(%Project{} = project, %{} = input, opts \\ []) do
    query = """
    mutation CommentCreate($input: CommentCreateInput!) {
      commentCreate(input: $input) {
        success
        comment {
          id
          body
          createdAt
        }
      }
    }
    """

    with {:ok, token} <- token(project, opts) do
      execute_query(token, query, %{"input" => input}, opts)
    end
  end

  defp put_file(%{"uploadUrl" => url} = upload_file, data_binary, opts) do
    headers = Enum.map(upload_file["headers"] || [], &{&1["key"], &1["value"]})

    case Req.put(build_req(opts), url: url, body: data_binary, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:linear_upload_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp oauth_config, do: Application.get_env(:rail, :linear_oauth, [])

  defp redirect_uri, do: RailWeb.Endpoint.url() <> "/auth/linear/callback"

  defp token(target, opts) do
    case opts[:as] do
      %Scope{user: %{}} = scope -> user_token(scope, target)
      _workspace -> workspace_token(target)
    end
  end

  defp user_token(scope, target) do
    case Users.linear_token(scope) do
      {:ok, token} ->
        {:ok, token}

      {:error, _not_linked} ->
        with {:ok, token} <- workspace_token(target) do
          Logger.warning("[rail] pushed to Linear as the workspace")
          {:ok, token}
        end
    end
  end

  defp workspace_token(%LinearWorkspace{token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp workspace_token(%Project{linear_workspace: %LinearWorkspace{token: token}})
       when is_binary(token) and token != "" do
    {:ok, token}
  end

  defp workspace_token(%Project{id: project_id}) when is_binary(project_id) do
    case Repo.get_by(LinearWorkspace, project_id: project_id) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" -> {:ok, token}
      _other -> {:error, :no_workspace_token}
    end
  end

  defp workspace_token(_fallback), do: {:error, :no_workspace_token}

  defp execute_query(token, query, variables, opts) do
    case Req.post(build_req(opts),
           url: @graphql_url,
           auth: {:bearer, token},
           json: %{query: query, variables: variables}
         ) do
      {:ok, %{status: 200, body: %{"errors" => [_error | _rest] = errors}}} -> {:error, {:linear_graphql_error, errors}}
      {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, data}
      {:ok, %{status: status, body: body}} -> {:error, {:linear_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_req(opts) do
    Req.new()
    |> Req.merge(Keyword.get(config(), :req_options, []))
    |> Req.merge(Keyword.get(opts, :req_options, []))
  end
end
