defmodule Rail.Mcp.Utils.McpToolsTest do
  use ExUnit.Case, async: true

  import Rail.Mcp.Utils.McpTools

  alias Rail.Roles.Schemas.Role

  setup do
    stages = [:plan, :engineer, :review_lead, :review, :qa, :screens, :demo, :triage]
    %{names: Map.new(stages, fn stage -> {stage, %Role{stage: stage} |> mcp_tools() |> Enum.map(& &1["name"])} end)}
  end

  # The engineer commits with git itself, and its turn ending is what hands the commits over.
  test "each stage that writes something is offered exactly its own save tool", %{names: names} do
    assert names[:plan] == [
             "save_design_option",
             "save_plan",
             "save_split",
             "ask_questions",
             "knowledge_search"
           ]

    assert names[:engineer] == ["save_report", "ask_questions", "knowledge_search"]
  end

  test "only the Plan, Engineer and Review leads are offered ask_questions, a list of prompts with options", %{
    names: names
  } do
    for_result = for({stage, offered} <- names, "ask_questions" in offered, do: stage)

    assert Enum.sort(for_result) ==
             [:engineer, :plan, :review_lead]

    for stage <- [:plan, :engineer, :review_lead] do
      assert %{
               "inputSchema" => %{
                 "required" => ["questions"],
                 "properties" => %{
                   "questions" => %{
                     "type" => "array",
                     "items" => %{
                       "type" => "object",
                       "required" => ["prompt"],
                       "properties" => %{
                         "prompt" => %{"type" => "string"},
                         "options" => %{"type" => "array", "items" => %{"type" => "string"}}
                       }
                     }
                   }
                 }
               }
             } = %Role{stage: stage} |> mcp_tools() |> Enum.find(&(&1["name"] == "ask_questions"))
    end
  end

  test "each agent that checks a round is offered its own tools, and the three that drive the app a browser",
       %{names: names} do
    browser = ["browser_connect", "browser_problems", "browser_close"]

    assert names[:qa] == browser ++ ["qa_plan", "qa_check", "qa_shot", "save_report", "knowledge_search"]
    assert names[:review] == ["save_report", "knowledge_search"]
    assert names[:screens] == browser ++ ["save_screen", "knowledge_search"]
    assert names[:demo] == browser ++ ["demo_start", "demo_say", "save_demo", "knowledge_search"]
  end

  test "the review agent is offered the tools it saves findings, the review and the next plan with, and no browser",
       %{names: names} do
    assert names[:review_lead] == ["save_finding", "save_fix_plan", "save_review", "ask_questions", "knowledge_search"]
  end

  test "save_report takes the whole report, for the agents nobody relays for", %{names: names} do
    for_result = for({stage, tools} <- names, "save_report" in tools, do: stage)
    assert Enum.sort(for_result) == [:engineer, :qa, :review]

    assert %{"inputSchema" => %{"properties" => %{"report" => %{"type" => "string"}}, "required" => ["report"]}} =
             %Role{stage: :qa} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_report"))
  end

  test "only the Review lead is offered save_fix_plan", %{names: names} do
    assert for({stage, tools} <- names, "save_fix_plan" in tools, do: stage) == [:review_lead]
  end

  # One save_finding holds both kinds and a fix round's report, so it takes a code range, evidence and a fix alike.
  test "save_finding takes a code finding's range, a screen finding's steps, evidence and a fix's report" do
    assert %{
             "inputSchema" => %{
               "required" => ["key"],
               "properties" => %{
                 "file" => %{"type" => "string"},
                 "steps" => %{"type" => "array"},
                 "covered" => %{"type" => "array", "items" => %{"type" => "integer"}},
                 "left" => %{"type" => "array", "items" => %{"required" => ["place", "reason"]}},
                 "test" => %{"type" => "object", "required" => ["file", "name"]},
                 "files" => %{"type" => "array", "items" => %{"type" => "string"}},
                 "evidence" => %{
                   "type" => "array",
                   "items" => %{
                     "properties" => %{"path" => %{"type" => "string"}, "browser" => %{"type" => "string"}},
                     "required" => ["name", "kind"]
                   }
                 }
               }
             }
           } = %Role{stage: :review_lead} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_finding"))
  end

  # Rail names the file, so a shot takes a caption and a browser and never a path.
  test "qa_shot takes what the picture shows, which browser and at what width, and nothing else" do
    assert %{"inputSchema" => %{"properties" => properties, "required" => ["name"]}} =
             %Role{stage: :qa} |> mcp_tools() |> Enum.find(&(&1["name"] == "qa_shot"))

    assert %{
             "name" => %{"type" => "string"},
             "browser" => %{"type" => "string"},
             "width" => %{"type" => "integer", "minimum" => 320, "maximum" => 1920}
           } = properties

    assert map_size(properties) == 3
  end

  # The key is what pairs a state's pictures across rounds, and Rail names the file.
  test "save_screen takes the state's key, what it shows, which browser and at what width, and never a path" do
    assert %{
             "inputSchema" => %{
               "properties" => %{"key" => %{"type" => "string"}, "label" => %{"type" => "string"}} = properties,
               "required" => ["key", "label"]
             }
           } = %Role{stage: :screens} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_screen"))

    assert Map.keys(properties) == ["browser", "key", "label", "width"]
  end

  test "a stage with no output of its own is offered only the knowledge base", %{names: names} do
    assert names[:triage] == ["knowledge_search"]

    # Product, design and architect run inside Plan, on its tools; no run holds those roles now.
  end

  test "save_plan takes the ticket, the plan and the design option it is written for, none of them required" do
    schema = %Role{stage: :plan} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_plan")) |> Map.fetch!("inputSchema")

    assert %{
             "title" => _title,
             "description" => _description,
             "priority" => %{"enum" => ["urgent", "high", "medium", "low"]},
             "estimate" => %{"type" => "integer"},
             "plan" => _plan,
             "design" => %{"type" => "string"}
           } = schema["properties"]

    refute Map.has_key?(schema, "required")
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
               "properties" => %{
                 "children" => %{
                   "items" => %{
                     "required" => ["title", "ticket", "plan"],
                     "properties" => %{"builds_screen" => %{"type" => "boolean"}}
                   }
                 }
               }
             }
           } = %Role{stage: :plan} |> mcp_tools() |> Enum.find(&(&1["name"] == "save_split"))

    assert description =~ "Each save replaces the whole split"
    assert description =~ "or the save is refused naming the child and the field"
  end
end
