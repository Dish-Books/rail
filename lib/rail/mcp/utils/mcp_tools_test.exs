defmodule Rail.Mcp.Utils.McpToolsTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.McpTools

  alias Rail.Roles.Schemas.Role

  setup do
    %{roles: Map.new([:qa, :review], fn stage -> {stage, %Role{stage: stage}} end)}
  end

  test "only a QA run is offered a browser", %{roles: roles} do
    assert roles[:qa] |> mcp_tools() |> Enum.map(& &1["name"]) == [
             "qa_plan",
             "qa_check",
             "qa_goto",
             "qa_do",
             "qa_look",
             "qa_shot",
             "qa_problems",
             "qa_stop"
           ]

    assert mcp_tools(roles[:review]) == []
  end
end
