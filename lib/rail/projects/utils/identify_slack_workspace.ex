defmodule Rail.Projects.Utils.IdentifySlackWorkspace do
  @moduledoc false

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Slack

  @doc """
  Asks Slack whose bot token a workspace changeset carries when the token
  changed, and puts the team and bot ids it answers with. A token Slack refuses
  is an error on the changeset. Returns `{:ok, changeset}` or `{:error, changeset}`.
  """
  def identify_slack_workspace(%Ecto.Changeset{valid?: true, changes: %{token: _token}} = changeset) do
    case changeset |> Ecto.Changeset.apply_changes() |> Slack.auth_test() do
      {:ok, identity} ->
        {:ok, SlackWorkspace.identity_changeset(changeset, identity)}

      {:error, {:slack_error, error}} ->
        {:error, Ecto.Changeset.add_error(changeset, :token, "was refused by Slack (#{error})")}

      {:error, _unreachable} ->
        {:error, Ecto.Changeset.add_error(changeset, :token, "could not be checked with Slack")}
    end
  end

  def identify_slack_workspace(%Ecto.Changeset{valid?: true} = changeset), do: {:ok, changeset}
  def identify_slack_workspace(changeset), do: {:error, changeset}
end
