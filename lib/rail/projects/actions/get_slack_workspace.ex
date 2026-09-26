defmodule Rail.Projects.Actions.GetSlackWorkspace do
  @moduledoc false

  alias Rail.Projects.Schemas.SlackWorkspace
  alias Rail.Repo

  @doc """
  Finds the Slack workspace matching `by`, e.g. `id: id` or `external_id: team_id`.
  """
  def get_slack_workspace(by) when is_list(by) do
    case Repo.get_by(SlackWorkspace, by) do
      %SlackWorkspace{} = workspace -> {:ok, workspace}
      nil -> {:error, :not_found}
    end
  end
end
