defmodule Rail.Users.Actions.SlackToken do
  @moduledoc false

  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users.Schemas.User

  @doc """
  The scope's user's Slack token and the workspace it is for, read fresh because
  a page's scope can predate the link. Slack user tokens do not expire.
  """
  def slack_token(%Scope{user: %{id: user_id}}) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      %User{slack_access_token: token, slack_team_id: team_id} when is_binary(token) and token != "" ->
        {:ok, token, team_id}

      _not_linked ->
        {:error, :not_linked}
    end
  end

  def slack_token(_scope), do: {:error, :not_linked}
end
