defmodule Rail.Mcp.Utils.McpToolsTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.McpTools

  alias Rail.Roles.Schemas.Role

  setup do
    stages = [:product, :design, :architect, :engineer, :review, :qa, :demo, :triage]
    %{names: Map.new(stages, fn stage -> {stage, %Role{stage: stage} |> mcp_tools() |> Enum.map(& &1["name"])} end)}
  end

  test "each stage that writes something is offered exactly its own save tool", %{names: names} do
    assert names[:product] == ["save_ticket"]
    assert names[:design] == ["save_design_option"]
    assert names[:architect] == ["save_plan"]
    assert names[:engineer] == ["commit", "request_merge"]
    assert names[:review] == ["save_finding", "save_review"]
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
             "save_verdict"
           ]
  end

  test "demo is offered the same browser, narrates, and saves its write-up", %{names: names} do
    assert names[:demo] == ["browser_connect", "browser_problems", "demo_start", "demo_say", "save_demo"]
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

  test "a stage with no output of its own is offered nothing", %{names: names} do
    assert names[:triage] == []
  end
end
