defmodule Rail.Issues.Utils.TokenResolver do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users

  require Logger

  def resolve_token(user_or_scope, project) do
    case user_token(user_or_scope) do
      {:ok, token} ->
        {:ok, token, :user}

      {:error, _reason} ->
        case workspace_token(project) do
          {:ok, token} ->
            Logger.warning("[axis] pushed to Linear as the workspace")
            {:ok, token, :workspace}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def workspace_token(%LinearWorkspace{token: token}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  def workspace_token(%Project{linear_workspace: %LinearWorkspace{token: token}}) when is_binary(token) and token != "" do
    {:ok, token}
  end

  def workspace_token(%Project{linear_workspace_id: ws_id}) when is_binary(ws_id) do
    case Repo.get(LinearWorkspace, ws_id) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end

  def workspace_token(_fallback) do
    case Repo.one(from lw in LinearWorkspace, limit: 1) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end

  defp user_token(nil), do: {:error, :not_linked}
  defp user_token(user_or_scope), do: Users.linear_token(user_or_scope)
end
