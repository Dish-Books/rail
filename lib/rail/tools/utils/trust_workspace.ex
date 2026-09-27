defmodule Rail.Tools.Utils.TrustWorkspace do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  @doc """
  Marks directories as trusted in a Claude backend's own config, as accepting
  Claude Code's trust dialog there would.

  Rail's agents never see that dialog, and until a workspace is trusted Claude
  Code ignores the permissions its `.claude/settings.json` allows. Trust has to
  land in the backend's config directory, not the one the CLI uses outside Rail,
  so accepting it by hand never reaches the agents. Other backends have no such
  dialog and are left alone, as is a config that already trusts every directory.
  """
  def trust_workspace(%Backend{name: :claude} = backend, paths) do
    config_path = Path.join(Backend.config_dir(backend), ".claude.json")
    config = read_config(config_path)

    projects =
      Enum.reduce(paths, config["projects"] || %{}, fn path, projects ->
        Map.update(projects, path, %{"hasTrustDialogAccepted" => true}, &Map.put(&1, "hasTrustDialogAccepted", true))
      end)

    if projects != config["projects"], do: write_config(config_path, Map.put(config, "projects", projects))
    :ok
  end

  def trust_workspace(%Backend{}, _paths), do: :ok

  # A missing or unreadable config starts empty: the CLI fills in the rest on
  # its first run.
  defp read_config(config_path) do
    with {:ok, content} <- File.read(config_path),
         {:ok, %{} = config} <- Jason.decode(content) do
      config
    else
      _missing_or_invalid -> %{}
    end
  end

  # Written aside and renamed over, so a CLI reading the config at the same
  # moment sees the old file or the new one, never half of either. The account
  # it holds stays readable only by its owner.
  defp write_config(config_path, config) do
    File.mkdir_p!(Path.dirname(config_path))
    tmp_path = "#{config_path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(tmp_path, Jason.encode_to_iodata!(config, pretty: true))
    File.chmod!(tmp_path, 0o600)
    File.rename!(tmp_path, config_path)
  end
end
