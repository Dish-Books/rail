defmodule RailWeb.Utils.SubagentNameTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.SubagentName

  test "an explorer is named by the browser its description starts with, and the rest is its work" do
    assert subagent_name("explorer", "explorer-1: Checks 1 and 2") == {"QA explorer 1", "Checks 1 and 2"}
  end

  test "an explorer whose description names no browser is the QA explorer, doing all of it" do
    assert subagent_name("explorer", "Checks 1 and 2") == {"QA explorer", "Checks 1 and 2"}
  end

  test "the other Review subagents are named by their type, with the description as their work" do
    assert subagent_name("code-reviewer", "Read the diff") == {"Code reviewer", "Read the diff"}
    assert subagent_name("engineer", "Fix round 1") == {"Engineer", "Fix round 1"}
    assert subagent_name("demo-recorder", "Record the demo") == {"Demo recorder", "Record the demo"}
  end

  test "any other type is not a Review subagent" do
    assert subagent_name("general-purpose", "Search the code") == nil
  end
end
