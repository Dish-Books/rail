defmodule Rail.Issues.Clients.Linear do
  @moduledoc """
  GraphQL and HTTP client for Linear issues, comments, workflow states, and uploads.
  """

  alias Rail.Domain.TicketBody

  @default_graphql_url "https://api.linear.app/graphql"

  def config do
    Application.get_env(:rail, :linear, Application.get_env(:rail, :linear_oauth, []))
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

    with {:ok, %{"viewer" => viewer}} <- execute_query(token, query, %{}, opts) do
      {:ok, %{id: viewer["id"], name: viewer["name"], email: viewer["email"]}}
    end
  end

  def issues(token, team_id, updated_since \\ nil, opts \\ []) do
    query = """
    query Issues($teamId: String!, $filter: IssueFilter) {
      team(id: $teamId) {
        issues(filter: $filter) {
          nodes {
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
            createdAt
            updatedAt
          }
        }
      }
    }
    """

    filter =
      if updated_since do
        iso_time = format_iso_time(updated_since)
        %{"updatedAt" => %{"gt" => iso_time}}
      end

    variables =
      if filter do
        %{"teamId" => team_id, "filter" => filter}
      else
        %{"teamId" => team_id}
      end

    with {:ok, data} <- execute_query(token, query, variables, opts) do
      nodes = get_in(data, ["team", "issues", "nodes"]) || []
      {:ok, Enum.map(nodes, &format_issue/1)}
    end
  end

  def issue(token, issue_id, opts \\ []) do
    query = """
    query Issue($id: String!) {
      issue(id: $id) {
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
        createdAt
        updatedAt
      }
    }
    """

    with {:ok, data} <- execute_query(token, query, %{"id" => issue_id}, opts) do
      case data["issue"] do
        %{} = issue_data ->
          {:ok, format_issue(issue_data)}

        nil ->
          {:error, :not_found}
      end
    end
  end

  def create_issue(token, attrs, opts \\ []) do
    query = """
    mutation IssueCreate($input: IssueCreateInput!) {
      issueCreate(input: $input) {
        success
        issue {
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
          createdAt
          updatedAt
        }
      }
    }
    """

    input =
      %{}
      |> put_if_present("teamId", get_attr(attrs, [:team_id, "team_id", :teamId, "teamId"]))
      |> put_if_present("title", get_attr(attrs, [:title, "title"]))
      |> put_if_present("description", get_attr(attrs, [:description, "description"]))
      |> put_if_present("stateId", get_attr(attrs, [:state_id, "state_id", :stateId, "stateId"]))
      |> put_if_present("priority", linear_priority(get_attr(attrs, [:priority, "priority"])))
      |> put_if_present("estimate", get_attr(attrs, [:estimate, "estimate"]))

    with {:ok, %{"issueCreate" => result}} <- execute_query(token, query, %{"input" => input}, opts) do
      if result["success"] do
        {:ok, format_issue(result["issue"])}
      else
        {:error, {:linear_mutation_failed, "issueCreate"}}
      end
    end
  end

  def update_issue(token, issue_id, attrs, opts \\ []) do
    query = """
    mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) {
      issueUpdate(id: $id, input: $input) {
        success
        issue {
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
          createdAt
          updatedAt
        }
      }
    }
    """

    input =
      %{}
      |> put_if_present("title", get_attr(attrs, [:title, "title"]))
      |> put_if_present("description", get_attr(attrs, [:description, "description"]))
      |> put_if_present("stateId", get_attr(attrs, [:state_id, "state_id", :stateId, "stateId"]))
      |> put_if_present("priority", linear_priority(get_attr(attrs, [:priority, "priority"])))
      |> put_if_present("estimate", get_attr(attrs, [:estimate, "estimate"]))

    with {:ok, %{"issueUpdate" => result}} <-
           execute_query(token, query, %{"id" => issue_id, "input" => input}, opts) do
      if result["success"] do
        {:ok, format_issue(result["issue"])}
      else
        {:error, {:linear_mutation_failed, "issueUpdate"}}
      end
    end
  end

  def workflow_states(token, team_id, opts \\ []) do
    query = """
    query WorkflowStates($teamId: String!) {
      team(id: $teamId) {
        states {
          nodes {
            id
            name
            type
          }
        }
      }
    }
    """

    with {:ok, data} <- execute_query(token, query, %{"teamId" => team_id}, opts) do
      case data["team"] do
        %{"states" => %{"nodes" => nodes}} ->
          formatted =
            Enum.map(nodes, fn s ->
              %{id: s["id"], name: s["name"], type: s["type"]}
            end)

          {:ok, formatted}

        nil ->
          {:error, :not_found}
      end
    end
  end

  def file_upload(token, filename, content_type, size, data_binary, opts \\ []) do
    query = """
    mutation FileUpload($filename: String!, $contentType: String!, $size: Int!) {
      fileUpload(filename: $filename, contentType: $contentType, size: $size) {
        success
        uploadFile {
          id
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

    variables = %{
      "filename" => filename,
      "contentType" => content_type,
      "size" => size
    }

    with {:ok, %{"fileUpload" => result}} <- execute_query(token, query, variables, opts) do
      if result["success"] do
        upload_file = result["uploadFile"]
        upload_url = upload_file["uploadUrl"]
        asset_url = upload_file["assetUrl"]
        asset_id = upload_file["id"]

        headers =
          Enum.map(upload_file["headers"] || [], fn %{"key" => k, "value" => v} ->
            {k, v}
          end)

        put_req =
          Req.new()
          |> Req.merge(Keyword.get(config(), :req_options, []))
          |> Req.merge(Keyword.get(opts, :req_options, []))

        case Req.put(put_req, url: upload_url, body: data_binary, headers: headers) do
          {:ok, %{status: status}} when status in [200, 201, 204] ->
            {:ok, %{asset_url: asset_url, asset_id: asset_id}}

          {:ok, %{status: status, body: body}} ->
            {:error, {:linear_upload_error, status, body}}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, {:linear_mutation_failed, "fileUpload"}}
      end
    end
  end

  def create_comment(token, issue_id, body, opts \\ []) do
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

    input = %{"issueId" => issue_id, "body" => body}

    with {:ok, %{"commentCreate" => result}} <- execute_query(token, query, %{"input" => input}, opts) do
      if result["success"] do
        comment = result["comment"]
        {:ok, %{id: comment["id"], body: comment["body"], created_at: comment["createdAt"]}}
      else
        {:error, {:linear_mutation_failed, "commentCreate"}}
      end
    end
  end

  def attachment_create(token, attrs, opts \\ []) do
    query = """
    mutation AttachmentCreate($input: AttachmentCreateInput!) {
      attachmentCreate(input: $input) {
        success
        attachment {
          id
          url
          title
        }
      }
    }
    """

    input =
      %{}
      |> put_if_present("issueId", get_attr(attrs, [:issue_id, "issue_id", :issueId, "issueId"]))
      |> put_if_present("url", get_attr(attrs, [:url, "url"]))
      |> put_if_present("title", get_attr(attrs, [:title, "title"]))

    with {:ok, %{"attachmentCreate" => result}} <- execute_query(token, query, %{"input" => input}, opts) do
      if result["success"] do
        attachment = result["attachment"]
        {:ok, %{id: attachment["id"], url: attachment["url"], title: attachment["title"]}}
      else
        {:error, {:linear_mutation_failed, "attachmentCreate"}}
      end
    end
  end

  defp execute_query(token, query, variables, opts) do
    req = build_req(opts)
    cfg = config()
    graphql_url = Keyword.get(opts, :graphql_url, Keyword.get(cfg, :graphql_url, @default_graphql_url))

    payload =
      if map_size(variables) == 0 do
        %{query: query}
      else
        %{query: query, variables: variables}
      end

    case Req.post(req,
           url: graphql_url,
           auth: {:bearer, token},
           json: payload
         ) do
      {:ok, %{status: 200, body: %{"errors" => errors}}} when is_list(errors) and errors != [] ->
        {:error, {:linear_graphql_error, errors}}

      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      {:ok, %{status: status, body: body}} ->
        {:error, {:linear_api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_req(opts) do
    cfg = config()
    req_options = Keyword.get(cfg, :req_options, [])
    custom_opts = Keyword.get(opts, :req_options, [])

    Req.new()
    |> Req.merge(req_options)
    |> Req.merge(custom_opts)
  end

  defp format_issue(node) when is_map(node) do
    %{
      id: node["id"],
      identifier: node["identifier"],
      title: node["title"],
      description: node["description"],
      priority: rail_priority(node["priority"]),
      estimate: node["estimate"],
      assignee_id: get_in(node, ["assignee", "id"]),
      state: format_issue_state(node["state"]),
      branch_name: node["branchName"],
      url: node["url"],
      created_at: node["createdAt"],
      updated_at: node["updatedAt"]
    }
  end

  defp format_issue_state(nil), do: nil

  defp format_issue_state(state) when is_map(state) do
    %{
      id: state["id"],
      name: state["name"],
      type: state["type"]
    }
  end

  defp get_attr(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_attr(list, keys) when is_list(list) do
    Enum.find_value(keys, fn
      key when is_atom(key) -> Keyword.get(list, key)
      _key -> nil
    end)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  @linear_priorities %{urgent: 1, high: 2, medium: 3, low: 4}

  defp linear_priority(nil), do: nil
  defp linear_priority(priority) when is_atom(priority), do: Map.get(@linear_priorities, priority)
  defp linear_priority(priority) when is_integer(priority) and priority in 0..4, do: priority

  defp linear_priority(priority) when is_binary(priority) do
    linear_priority(TicketBody.cast_priority(priority))
  end

  defp linear_priority(_other), do: nil

  defp rail_priority(number) when is_integer(number), do: TicketBody.cast_priority(number)
  defp rail_priority(_other), do: nil

  defp format_iso_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_iso_time(str) when is_binary(str), do: str
end
