defmodule RailWeb.Utils.CustomStageItemTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.CustomStageItem

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage

  test "a custom stage's item is named by its position, found by its key or its name" do
    issue = %Issue{
      stages: [
        %IssueStage{stage: :plan},
        %IssueStage{stage: :custom, name: "Schema review", prompt: "Read the migrations."}
      ]
    }

    assert %{key: "stage-2", name: "Schema review", position: 2} = custom_stage_item(issue, "stage-2")
    assert %{key: "stage-2"} = custom_stage_item(issue, {:custom, "Schema review"})
    assert custom_stage_item(issue, {:custom, "Gone"}) == nil
    assert custom_stage_item(issue, "stage-1") == nil
    assert custom_stage_item(issue, "stage-0") == nil
    assert custom_stage_item(issue, "stage-x") == nil
    assert custom_stage_item(issue, :plan) == nil
  end
end
