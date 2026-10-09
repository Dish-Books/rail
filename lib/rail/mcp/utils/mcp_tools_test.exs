defmodule Rail.Mcp.Utils.McpToolsTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.McpTools

  alias Rail.Roles.Schemas.Role

  setup do
    stages = [:plan, :product, :design, :architect, :engineer, :review_lead, :review, :qa, :demo, :triage]
    %{names: Map.new(stages, fn stage -> {stage, %Role{stage: stage} |> mcp_tools() |> Enum.map(& &1["name"])} end)}
  end

  test "each stage that writes something is offered exactly its own save tool", %{names: names} do
    assert names[:plan] == ["save_ticket", "save_design_option", "save_plan", "save_split", "knowledge_search"]
    assert names[:engineer] == ["commit", "request_merge", "knowledge_search"]
  end

  test "the Review lead is offered the browser, the checklist, the camera, and the tools it reports with",
       %{names: names} do
    assert names[:review_lead] == [
             "browser_connect",
             "browser_problems",
             "qa_plan",
             "qa_check",
             "qa_shot",
             "qa_file",
             "demo_start",
             "demo_say",
             "save_finding",
             "save_review",
             "commit_fixes",
             "save_demo",
             "knowledge_search"
           ]
  end

  # One save_finding holds both kinds, so it takes a code range and evidence alike.
  test "save_finding takes a code finding's range, a screen finding's steps, and evidence" do
    assert %{
             "inputSchema" => %{
               "required" => ["key"],
               "properties" => %{
                 "file" => %{"type" => "string"},
                 "steps" => %{"type" => "array"},
                 "evidence" => %{"type" => "array"}
               }
             }
           } = %Role{stage: :review_lead} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_finding"))
  end

  test "the lead's subagents are offered only the knowledge base", %{names: names} do
    assert names[:review] == ["knowledge_search"]
    assert names[:qa] == ["knowledge_search"]
    assert names[:demo] == ["knowledge_search"]
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
