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
             "qa_file",
             "knowledge_search"
           ]
  end

  test "demo is offered the same browser and narrates instead", %{roles: roles} do
    assert roles[:demo] |> mcp_tools() |> Enum.map(& &1["name"]) == [
             "browser_connect",
             "browser_problems",
             "demo_start",
             "demo_say",
             "knowledge_search"
           ]
  end

  test "every other stage reads code and is offered only the knowledge base", %{roles: roles} do
    assert [%{"name" => "knowledge_search"}] = mcp_tools(roles[:review])
  end

  test "every role stage is offered knowledge_search" do
    for stage <- Role.canonical_stages() do
      assert Enum.any?(mcp_tools(%Role{stage: stage}), &(&1["name"] == "knowledge_search"))
    end
  end
end
