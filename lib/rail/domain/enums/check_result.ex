defmodule Rail.Domain.Enums.CheckResult do
  @moduledoc """
  Result of a QA check row.
  """
  use Rail.Domain.Enums.Type,
    values: [
      :pass,
      :fail,
      :warn,
      :skip
    ],
    labels: %{
      pass: "Pass",
      fail: "Fail",
      warn: "Warn",
      skip: "Skip"
    }

  @doc "Returns true if the check passed."
  def pass?(:pass), do: true
  def pass?(_other), do: false

  @doc "Returns true if the check failed."
  def fail?(:fail), do: true
  def fail?(_other), do: false

  @doc "Returns true if the check resulted in a warning."
  def warn?(:warn), do: true
  def warn?(_other), do: false

  @doc "Returns true if the check was skipped."
  def skip?(:skip), do: true
  def skip?(_other), do: false
end
