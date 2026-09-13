defmodule Rail.Issues.Utils.TokenResolver do
  @moduledoc """
  Picks the Linear token a write goes out under.

  A write the pipeline can attribute to a person goes out as that person, so
  Linear shows their name on it; everything else — and anything by a user who
  never linked Linear — goes out as the workspace.
  """

  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Users

  require Logger

  def resolve_token(user, project) do
    case user_token(user) do
      {:ok, token} ->
        {:ok, token, :user}

      {:error, _reason} ->
        case workspace_token(project) do
          {:ok, token} ->
            Logger.warning("[rail] pushed to Linear as the workspace")
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

  def workspace_token(%Project{id: project_id}) when is_binary(project_id) do
    case Repo.get_by(LinearWorkspace, project_id: project_id) do
      %LinearWorkspace{token: token} when is_binary(token) and token != "" ->
        {:ok, token}

      _other ->
        {:error, :no_workspace_token}
    end
  end

  def workspace_token(_fallback), do: {:error, :no_workspace_token}

  defp user_token(nil), do: {:error, :not_linked}
  defp user_token(user), do: Users.linear_token(user)
end
