defmodule Rail.Projects.Actions.GetSlackChannel do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo

  @doc """
  Finds the channel matching `by`, with the workspace it is in and the project
  it routes to, that project's triage user included.
  """
  def get_slack_channel(by) when is_list(by) do
    case Repo.one(from c in SlackChannel, where: ^by, preload: [:slack_workspace, project: :triage_user]) do
      %SlackChannel{} = channel -> {:ok, channel}
      nil -> {:error, :not_found}
    end
  end
end
