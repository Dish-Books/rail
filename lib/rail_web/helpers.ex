defmodule RailWeb.Helpers do
  @moduledoc """
  The formatting every template reaches for, in one import.

  `RailWeb.html_helpers/0` imports this, so a LiveView, LiveComponent or function
  component can call any of it without an alias.
  """

  alias RailWeb.Utils

  defdelegate format_duration(seconds), to: Utils.FormatDuration
  defdelegate format_run_status(status), to: Utils.FormatRunStatus
end
