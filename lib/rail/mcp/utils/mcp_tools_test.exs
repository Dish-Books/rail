defmodule Rail.Mcp.Utils.McpToolsTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.McpTools

  alias Rail.Roles.Schemas.Role

  setup do
    %{roles: Map.new([:qa, :demo, :review], fn stage -> {stage, %Role{stage: stage}} end)}
  end

  test "QA is offered the browser and the checklist it reports with", %{roles: roles} do
    assert roles[:qa] |> mcp_tools() |> Enum.map(& &1["name"]) == [
             "browser_connect",
             "browser_problems",
             "qa_plan",
             "qa_check",
             "qa_shot",
             "qa_file"
           ]
  end

  test "demo is offered the same browser and narrates instead", %{roles: roles} do
    assert roles[:demo] |> mcp_tools() |> Enum.map(& &1["name"]) == [
             "browser_connect",
             "browser_problems",
             "demo_start",
             "demo_say"
           ]
  end

  test "every other stage reads code and is offered nothing", %{roles: roles} do
    assert mcp_tools(roles[:review]) == []
  end
end
