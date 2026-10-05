defmodule Rail.Tools.Utils.AnnounceLostSession do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Projects.Schemas.SlackChannel
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Slack
  alias Rail.Tools.Schemas.Backend

  require Logger

  @doc """
  Tells every project with a role on `backend` that it lost its sign-in with
  nobody signing it out, in the channel the project's learnings digest posts in.
  A channel several projects share is told once, and one marked external never.
  """
  def announce_lost_session(%Backend{id: backend_id} = backend) do
    projects =
      Repo.all(
        from p in Project,
          where: not is_nil(p.learnings_channel_external_id),
          where: p.id in subquery(from r in Role, where: r.backend_id == ^backend_id, select: r.project_id),
          preload: :learnings_slack_workspace
      )

    for {workspace, channel} <-
          projects |> Enum.map(&{&1.learnings_slack_workspace, &1.learnings_channel_external_id}) |> Enum.uniq(),
        not external?(workspace, channel) do
      with {:error, reason} <- Slack.post_channel_message(workspace, channel, text(backend)) do
        Logger.warning("Could not tell #{channel} that a backend lost its sign-in: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp external?(workspace, channel) do
    match?(
      {:ok, %SlackChannel{external: true}},
      Projects.get_slack_channel(external_id: channel, slack_workspace_id: workspace.id)
    )
  end

  defp text(%Backend{} = backend) do
    "Rail's #{backend.label || backend.name} backend lost its sign-in. " <>
      "Runs on it are held until someone signs it in again: #{RailWeb.Endpoint.url()}/settings/backends"
  end
end
