defmodule RailWeb.Utils.SubagentName do
  @moduledoc """
  A Review subagent as a reader knows it, from the type the lead handed it work as and the description it
  gave: an explorer's description starts with its browser, which numbers it.
  """

  import RailWeb.Utils.BrowserLabel

  @names %{"code-reviewer" => "Code reviewer", "engineer" => "Engineer", "demo-recorder" => "Demo recorder"}

  @doc """
  Returns `{name, work}` for a Review subagent of type `label` given `description`, or `nil` for any other type.
  """
  def subagent_name("explorer", description) when is_binary(description) do
    case Regex.run(~r/^\s*(explorer-\d+)\s*:\s*(.*)$/s, description) do
      [_whole, browser, work] -> {browser_label(browser), String.trim(work)}
      nil -> {"QA explorer", description}
    end
  end

  def subagent_name(label, description) when is_map_key(@names, label), do: {Map.fetch!(@names, label), description}
  def subagent_name(_label, _description), do: nil
end
