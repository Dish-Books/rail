defmodule Rail.Triage.Utils.CanPostToSlack do
  @moduledoc false

  alias Rail.Scope
  alias Rail.Triage.Schemas.Thread
  alias Rail.Users

  @doc """
  Whether the scope's user can post in `thread` as themselves: they linked Slack,
  in the thread's workspace. Checked before anything is claimed or created. Needs
  the thread's channel and workspace preloaded.
  """
  def can_post_to_slack(%Scope{} = scope, %Thread{slack_channel: channel}) do
    case Users.slack_token(scope) do
      {:ok, _token, team_id} ->
        if team_id == channel.slack_workspace.external_id, do: :ok, else: {:error, :slack_other_workspace}

      {:error, :not_linked} ->
        {:error, :slack_not_linked}
    end
  end
end
