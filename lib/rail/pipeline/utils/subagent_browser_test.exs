defmodule Rail.Pipeline.Utils.SubagentBrowserTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.SubagentBrowser

  test "an explorer drives the browser its description starts with" do
    assert subagent_browser("explorer", "explorer-3: Checks 4 and 5") == "explorer-3"
    assert subagent_browser("explorer", "  explorer-12 : Check 1") == "explorer-12"
  end

  test "an explorer whose description names no browser has none to close" do
    assert subagent_browser("explorer", "Checks 4 and 5") == nil
    assert subagent_browser("explorer", nil) == nil
  end

  test "the demo recorder drives `demo`, and no other subagent drives a browser" do
    assert subagent_browser("demo-recorder", "Record the shot list") == "demo"
    assert subagent_browser("code-reviewer", "explorer-1: Read the diff") == nil
    assert subagent_browser("engineer", "Fix the findings") == nil
  end
end
