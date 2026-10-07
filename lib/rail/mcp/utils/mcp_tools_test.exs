defmodule Rail.Mcp.Utils.McpToolsTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.McpTools

  alias Rail.Roles.Schemas.Role

  setup do
    stages = [:plan, :product, :design, :architect, :engineer, :review, :qa, :demo, :triage]
    %{names: Map.new(stages, fn stage -> {stage, %Role{stage: stage} |> mcp_tools() |> Enum.map(& &1["name"])} end)}
  end

  test "each stage that writes something is offered exactly its own save tool", %{names: names} do
    assert names[:plan] == ["save_ticket", "save_design_option", "save_plan", "save_split", "knowledge_search"]
    assert names[:engineer] == ["commit", "request_merge", "knowledge_search"]
    assert names[:review] == ["save_finding", "save_review", "knowledge_search"]
  end

  test "QA is offered the browser, the checklist, and the tools it reports with", %{names: names} do
    assert names[:qa] == [
             "browser_connect",
             "browser_problems",
             "qa_plan",
             "qa_check",
             "qa_shot",
             "qa_file",
             "save_finding",
             "save_verdict",
             "knowledge_search"
           ]
  end

  test "demo is offered the same browser, narrates, and saves its write-up", %{names: names} do
    assert names[:demo] == [
             "browser_connect",
             "browser_problems",
             "demo_start",
             "demo_say",
             "save_demo",
             "knowledge_search"
           ]
  end

  # Both are called save_finding, and each takes the fields its own stage raises.
  test "review's and QA's save_finding take their own fields" do
    fields = fn stage ->
      %Role{stage: stage}
      |> mcp_tools()
      |> Enum.find(&(&1["name"] == "save_finding"))
      |> get_in(["inputSchema", "properties"])
    end

    assert Map.has_key?(fields.(:review), "file")
    refute Map.has_key?(fields.(:review), "evidence")
    assert Map.has_key?(fields.(:qa), "evidence")
    refute Map.has_key?(fields.(:qa), "file")
  end

  test "a stage with no output of its own is offered only the knowledge base", %{names: names} do
    assert names[:triage] == ["knowledge_search"]

    # Product, design and architect run inside Plan, on its tools; no run holds those roles now.
    assert names[:product] == ["knowledge_search"]
    assert names[:design] == ["knowledge_search"]
    assert names[:architect] == ["knowledge_search"]
  end

  test "save_plan takes the plan and, optionally, the design option it was written for" do
    assert %{"properties" => %{"plan" => _plan, "design" => %{"type" => "string"}}, "required" => ["plan"]} =
             %Role{stage: :plan} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_plan")) |> Map.fetch!("inputSchema")
  end

  test "every role stage is offered knowledge_search" do
    for stage <- Role.canonical_stages() do
      assert Enum.any?(mcp_tools(%Role{stage: stage}), &(&1["name"] == "knowledge_search"))
    end
  end

  test "save_split takes every child at once, each needing its title, ticket and part of the plan" do
    assert %{
             "description" => description,
             "inputSchema" => %{
               "required" => ["children"],
               "properties" => %{"children" => %{"items" => %{"required" => ["title", "ticket", "plan"]}}}
             }
           } = %Role{stage: :plan} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_split"))

    assert description =~ "Each save replaces the whole split"
    assert description =~ "or the save is refused naming the child and the field"
  end
end
