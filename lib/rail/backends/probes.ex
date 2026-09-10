defmodule Rail.Backends.Probes do
  @moduledoc """
  Shared defaults and utilities for CLI backend usage probes.
  """

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
