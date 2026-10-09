defmodule Rail.Tools.Utils.RequestToolchainInstall do
  @moduledoc false

  import Ecto.Query

  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools.Schemas.ToolchainInstall
  alias Rail.Tools.Workers.InstallToolchain

  @doc """
  Queues one run of `project`'s toolchain command for `head_sha`.

  The command runs once for a commit: `{:ok, install}` is the one queued, or the
  one already there, whatever became of it. Only `retry: true` queues another.
  """
  def request_toolchain_install(%Project{id: project_id, toolchain_command: command}, head_sha, opts \\ [])
      when is_binary(command) and is_binary(head_sha) do
    :global.trans({:rail_toolchain_request, self()}, fn ->
      latest =
        Repo.one(
          from i in ToolchainInstall,
            where: i.project_id == ^project_id and i.head_sha == ^head_sha and i.command == ^command,
            order_by: [desc: i.id],
            limit: 1
        )

      queued? = match?(%ToolchainInstall{status: status} when status in [:queued, :installing], latest)

      if is_nil(latest) or (Keyword.get(opts, :retry, false) and not queued?),
        do: {:ok, queue(project_id, command, head_sha)},
        else: {:ok, latest}
    end)
  end

  defp queue(project_id, command, head_sha) do
    {:ok, install} =
      Repo.transaction(fn ->
        install =
          %ToolchainInstall{}
          |> ToolchainInstall.changeset(%{command: command, head_sha: head_sha}, project_id)
          |> Repo.insert!()

        {:ok, _job} = %{install_id: install.id} |> InstallToolchain.new() |> Oban.insert()
        install
      end)

    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    install
  end
end
