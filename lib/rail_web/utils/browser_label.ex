defmodule RailWeb.Utils.BrowserLabel do
  @moduledoc """
  A browser as a reader knows it: `explorer-N` is QA explorer N, `demo` the Demo recorder and `plan` the Plan
  designer's.
  """

  @doc """
  Labels the browser `name`, or returns the name as given when it is neither.
  """
  def browser_label("demo"), do: "Demo recorder"
  def browser_label("plan"), do: "Plan designer"

  def browser_label("explorer-" <> number = name) do
    if String.match?(number, ~r/^\d+$/), do: "QA explorer #{number}", else: name
  end

  def browser_label(name) when is_binary(name), do: name
end
