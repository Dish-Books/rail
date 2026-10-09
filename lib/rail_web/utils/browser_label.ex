defmodule RailWeb.Utils.BrowserLabel do
  @moduledoc """
  A Review browser as a reader knows it: `explorer-N` is QA explorer N and `demo` the Demo recorder.
  """

  @doc """
  Labels the browser `name`, or returns the name as given when it is neither.
  """
  def browser_label("demo"), do: "Demo recorder"

  def browser_label("explorer-" <> number = name) do
    if String.match?(number, ~r/^\d+$/), do: "QA explorer #{number}", else: name
  end

  def browser_label(name) when is_binary(name), do: name
end
