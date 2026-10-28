defmodule RailWeb.Utils.StageOutputRecipientsTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.StageOutputRecipients

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage

  test "names each stage after the custom one, one of them alone" do
    issue = %Issue{
      stages: [
        %IssueStage{stage: :custom, name: "Missing strings", prompt: "List them."},
        %IssueStage{stage: :plan},
        %IssueStage{stage: :engineer},
        %IssueStage{stage: :custom, name: "License check", prompt: "Check them."},
        %IssueStage{stage: :review}
      ]
    }

    assert stage_output_recipients(issue, "License check") == "Review gets this file"

    assert stage_output_recipients(issue, "Missing strings") ==
             "Plan, Implement, License check and Review get this file"
  end
end
