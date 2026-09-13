defmodule Rail.Tools.Utils.MergedPath do
  @moduledoc """
  The PATH external tools run with: the inherited `PATH` followed by the user's
  home bin directories and the well-known system ones, deduplicated and in
  search order.
  """

  @separator ":"

  @fallback_dirs [
    "/opt/homebrew/bin",
    "/opt/homebrew/sbin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin"
  ]

  @doc """
  Builds the merged PATH, reading the inherited `PATH` when `sys_path` is not given.
  """
  def merged_path(sys_path \\ nil) do
    home = System.get_env("HOME") || ""

    home_dirs =
      if home == "" do
        []
      else
        [Path.join(home, ".local/bin"), Path.join(home, "bin")]
      end

    (segments(sys_path || System.get_env("PATH")) ++ home_dirs ++ @fallback_dirs)
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
    |> Enum.join(@separator)
  end

  defp segments(path) when is_binary(path) and path != "", do: String.split(path, @separator)
  defp segments(_other), do: []
end
