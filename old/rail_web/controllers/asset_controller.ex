defmodule RailWeb.AssetController do
  @moduledoc """
  Controller proxying private Linear asset files for authenticated users.
  Verifies that requested URLs are stored on existing artifacts in Postgres
  to prevent SSRF attacks.
  """
  use RailWeb, :controller

  import Ecto.Query

  alias Rail.Artifacts
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Streams a proxied asset if the requesting user is authenticated and the asset
  exists on a stored artifact.
  """
  def show(conn, %{"kind" => kind, "id" => id}) do
    scope = conn.assigns[:current_scope]

    if authorized?(scope) do
      case Artifacts.get_asset(scope, kind, id) do
        {:ok, asset} ->
          proxy_asset(conn, asset)

        {:error, :not_found} ->
          conn
          |> put_status(:not_found)
          |> text("Not found")
      end
    else
      conn
      |> put_status(:unauthorized)
      |> text("Unauthorized")
    end
  end

  defp authorized?(%Scope{system: true}), do: true
  defp authorized?(%Scope{user: %{}}), do: true
  defp authorized?(_scope), do: false

  defp proxy_asset(conn, asset) do
    case resolve_workspace_token() do
      {:ok, token} ->
        req_options = Application.get_env(:rail, :linear, [])[:req_options] || []

        req = Req.merge(Req.new(), req_options)

        headers = [{"authorization", token}]

        case Req.get(req, url: asset.url, headers: headers, retry: false) do
          {:ok, %{status: 200, body: body, headers: resp_headers}} ->
            content_type =
              resp_headers["content-type"] |> List.wrap() |> List.first() ||
                asset[:content_type] ||
                "application/octet-stream"

            conn
            |> put_resp_content_type(content_type)
            |> send_resp(200, body)

          {:ok, %{status: status}} ->
            conn
            |> put_status(:bad_gateway)
            |> text("Failed to fetch asset from Linear: HTTP #{status}")

          {:error, reason} ->
            conn
            |> put_status(:bad_gateway)
            |> text("Failed to fetch asset from Linear: #{inspect(reason)}")
        end

      {:error, :no_workspace_token} ->
        conn
        |> put_status(:bad_gateway)
        |> text("Linear workspace token not configured")
    end
  end

  defp resolve_workspace_token do
    case Repo.one(from lw in LinearWorkspace, limit: 1) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end
end
