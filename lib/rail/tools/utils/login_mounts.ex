defmodule Rail.Tools.Utils.LoginMounts do
  @moduledoc false

  alias Rail.Tools.Schemas.Backend

  # Earlier sessions, which a sandbox must not read, and what later runs load, which it must not leave behind.
  @hidden_dirs [
    "projects",
    "sessions",
    "session-env",
    "shell-snapshots",
    "todos",
    "file-history",
    "backups",
    "agents",
    "commands",
    "skills",
    "plugins",
    "output-styles",
    "rules"
  ]
  @locked_files %{"settings.json" => "{}", "settings.local.json" => "{}", "CLAUDE.md" => ""}

  @doc """
  The binds and tmpfs a sandbox needs for `backend`'s login, with each of `writable_dirs` left open under the cover.
  Returns `%{binds: binds, tmpfs: tmpfs}`.
  """
  def login_mounts(%Backend{} = backend, writable_dirs) when is_list(writable_dirs) do
    config_dir = Backend.config_dir(backend)
    hidden = Enum.map(@hidden_dirs, &Path.join(config_dir, &1))
    locked = Enum.map(Map.keys(@locked_files), &Path.join(config_dir, &1))

    # Docker mounts over these, and would make a missing one as root, which later runs on the account could not write.
    Enum.each(hidden ++ writable_dirs, &File.mkdir_p!/1)

    Enum.each(@locked_files, fn {name, empty} ->
      case File.write(Path.join(config_dir, name), empty, [:exclusive]) do
        :ok -> :ok
        {:error, :eexist} -> :ok
      end
    end)

    %{
      binds: Enum.map([config_dir | writable_dirs], &"#{&1}:#{&1}") ++ Enum.map(locked, &"#{&1}:#{&1}:ro"),
      tmpfs: Map.new(hidden, &{&1, "uid=1000,gid=1000,mode=0700"})
    }
  end
end
