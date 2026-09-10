defmodule Rail.Backends.Probes do
  @moduledoc """
  Shared defaults and utilities for CLI backend usage probes.
  """

  @doc """
  Returns the executable path the user configured for a backend, or `""` when
  the backend has not been configured yet.
  """
  def configured_path(name) do
    case Rail.Backends.get_backend(name) do
      %{executable_path: path} when is_binary(path) -> path
      _unconfigured -> ""
    end
  end

  @doc """
  Validates that a path is a non-blank, existing, executable regular file.
  """
  def default_path_validator(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        Bitwise.band(mode, 0o111) != 0

      _other ->
        false
    end
  end

  def default_path_validator(_other), do: false

  @doc """
  Reads the content of a configuration file.
  """
  def default_config_file_reader(path) when is_binary(path) do
    File.read(path)
  end
end
