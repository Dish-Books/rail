defmodule Rail.Tools.Actions.InstallToolchain do
  @moduledoc false

  import Rail.Tools.Utils.DecodeUtf8Lenient

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Tools
  alias Rail.Tools.Schemas.ToolchainInstall

  # Erlang from source is most of an hour on a busy machine.
  @timeout_ms to_timeout(minute: 90)
  @kept_output_bytes 20_000

  @doc """
  Runs a queued install's command through `/bin/sh` in a checkout of the project's
  default branch, beside Rail rather than in a sandbox, so no role's memory cap
  applies and what it builds with is kept. One at a time on this machine.

  Returns `{:ok, install}`, finished or failed with the end of what the command
  wrote, or `{:error, :not_queued}` for one that has settled or is gone.
  """
  def install_toolchain(install_id) do
    :global.trans({:rail_toolchain_install, self()}, fn ->
      case ToolchainInstall |> Repo.get(install_id) |> Repo.preload(:project) do
        %ToolchainInstall{status: status} = install when status in [:queued, :installing] ->
          settled = install |> update(%{status: :installing, started_at: DateTime.utc_now()}) |> run()
          {:ok, settled}

        _settled_or_gone ->
          {:error, :not_queued}
      end
    end)
  end

  defp run(%ToolchainInstall{project: %Project{} = project, command: command} = install) do
    with {:ok, checkout} <- Git.checkout_detached_worktree(project, ToolchainInstall.checkout_path(project)),
         {_output, 0} <-
           Tools.run("/bin/sh", ["-c", command], cd: checkout, stderr_to_stdout: true, timeout: @timeout_ms) do
      update(install, %{status: :finished, ended_at: DateTime.utc_now()})
    else
      {output, code} when is_binary(output) and is_integer(code) -> fail(install, output)
      # coveralls-ignore-next-line (a command still going after ninety minutes)
      {:error, :timeout} -> fail(install, "Stopped: it was still going after #{div(@timeout_ms, 60_000)} minutes.")
      {:error, reason} when is_binary(reason) -> fail(install, reason)
      # coveralls-ignore-next-line (a checkout refused for something other than what git said)
      {:error, reason} -> fail(install, inspect(reason))
    end
  end

  defp fail(install, output) do
    kept = binary_part(output, max(byte_size(output) - @kept_output_bytes, 0), min(byte_size(output), @kept_output_bytes))
    update(install, %{status: :failed, ended_at: DateTime.utc_now(), output: decode_utf8_lenient(kept)})
  end

  defp update(%ToolchainInstall{project_id: project_id} = install, attrs) do
    updated = install |> ToolchainInstall.changeset(attrs, project_id) |> Repo.update!()
    Phoenix.PubSub.broadcast(Rail.PubSub, "sandboxes", :sandboxes_changed)
    updated
  end
end
