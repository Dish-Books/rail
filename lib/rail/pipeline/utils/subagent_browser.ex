defmodule Rail.Pipeline.Utils.SubagentBrowser do
  @moduledoc false

  @doc """
  The browser a Review subagent of type `type` drives, from the description the lead handed it work with:
  an explorer's starts with its browser's name, and the demo recorder's is always `demo`. Returns `nil`
  for a subagent with no browser, and for an explorer whose description names none.
  """
  def subagent_browser("demo-recorder", _description), do: "demo"

  def subagent_browser("explorer", description) when is_binary(description) do
    case Regex.run(~r/^\s*(explorer-\d+)\s*:/, description) do
      [_whole, browser] -> browser
      nil -> nil
    end
  end

  def subagent_browser(_type, _description), do: nil
end
