defmodule Rail.Users.Actions.LinkSlack do
  @moduledoc """
  Connects the scope's user to their Slack account from an OAuth callback, so
  what they accept in triage is posted as them.
  """

  alias Rail.Projects
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Slack
  alias Rail.Users.Schemas.User

  @doc """
  Trades the authorization `code` for the person's token, reads their name
  through the workspace's bot, and stores both on the scope's user.
  """
  def link_slack(%Scope{user: %User{} = user}, code) when is_binary(code) do
    with {:ok, %{"team" => %{"id" => team_id}, "authed_user" => %{"id" => slack_user_id, "access_token" => token}}} <-
           Slack.exchange_code(code),
         {:ok, workspace} <- workspace(team_id),
         {:ok, slack_user} <- Slack.user_info(workspace, slack_user_id) do
      user
      |> User.changeset(%{
        slack_user_id: slack_user_id,
        slack_team_id: team_id,
        slack_name: get_in(slack_user, ["profile", "real_name"]) || slack_user["real_name"] || slack_user["name"],
        slack_access_token: token
      })
      |> Repo.update()
    end
  end

  def link_slack(_scope, _code), do: {:error, :not_authenticated}

  defp workspace(team_id) do
    case Projects.get_slack_workspace(external_id: team_id) do
      {:ok, workspace} -> {:ok, workspace}
      {:error, :not_found} -> {:error, :slack_workspace_not_found}
    end
  end
end
