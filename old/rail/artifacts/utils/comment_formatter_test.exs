defmodule Rail.Artifacts.Utils.CommentFormatterTest do
  use ExUnit.Case, async: true

  import Rail.Artifacts.Utils.CommentFormatter

  alias Rail.Artifacts.Schemas.Demo
  alias Rail.Artifacts.Schemas.QaReport
  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment
  alias Rail.Domain.Embeds.QaRow

  describe "format_demo_comment/1" do
    test "formats declined demo comment" do
      demo = %Demo{version: 1, outcome: "declined", note: "No UI changes in this backend ticket."}
      comment = format_demo_comment(demo)
      assert comment =~ "## Demo (v1): declined"
      assert comment =~ "No UI changes in this backend ticket."
    end

    test "formats recorded demo comment with segments and frames" do
      frame = %DemoFrame{
        url: "https://linear.app/asset/frame_1.png",
        caption: "Main screen loaded"
      }

      frame2 = %DemoFrame{
        url: "https://linear.app/asset/frame_2.png",
        caption: ""
      }

      seg1 = %DemoSegment{
        criterion_index: 1,
        criterion: "User can sign in",
        outcome: :recorded,
        frames: [frame, frame2]
      }

      seg2 = %DemoSegment{
        criterion_index: 2,
        criterion: "Background job fires",
        outcome: :not_filmable,
        note: "Runs in headless worker"
      }

      demo = %Demo{version: 1, outcome: "recorded", segments: [seg1, seg2]}
      comment = format_demo_comment(demo)

      assert comment =~ "## Demo (v1): 1/2 criteria recorded"
      assert comment =~ "### Criterion 1: User can sign in"
      assert comment =~ "![Main screen loaded](https://linear.app/asset/frame_1.png)"
      assert comment =~ "*Outcome: not_filmable* - Runs in headless worker"
    end
  end

  describe "format_qa_comment/1" do
    test "formats QA report summary and checks table" do
      row1 = %QaRow{
        id: "c1",
        check: "Database migration succeeds",
        result: :pass,
        severity: :blocker,
        caused_by_change: true
      }

      row2 = %QaRow{
        id: "c2",
        check: "LiveView connects",
        result: :fail,
        severity: :major,
        caused_by_change: true
      }

      report = %QaReport{commit: "f1a2b3c", rows: [row1, row2]}
      comment = format_qa_comment(report)

      assert comment =~ "## QA Report"
      assert comment =~ "Commit: `f1a2b3c`"
      assert comment =~ "Summary: 1 passed, 1 failed, 0 skipped"
      assert comment =~ "| Database migration succeeds | pass | blocker | true |"
      assert comment =~ "| LiveView connects | fail | major | true |"
    end
  end
end
