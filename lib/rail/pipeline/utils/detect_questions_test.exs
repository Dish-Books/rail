defmodule Rail.Pipeline.Utils.DetectQuestionsTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.DetectQuestions

  alias Rail.Pipeline.DetectedQuestion

  test "detects a question on its own line" do
    assert [%DetectedQuestion{prompt: "Which database should we use?", options: []}] =
             detect_questions("[QUESTION: Which database should we use?]")
  end

  test "detects question with options" do
    assert [%DetectedQuestion{prompt: "Scope to one repo?", options: ["yes", "no"]}] =
             detect_questions("[QUESTION: Scope to one repo?] [OPTIONS: yes, no]")
  end

  test "options parsing trims and rejects empty options" do
    assert [%DetectedQuestion{options: ["vanilla", "chocolate", "strawberry"]}] =
             detect_questions("[QUESTION: Which flavor?] [OPTIONS:  vanilla , , chocolate , strawberry ]")
  end

  test "detects question case-insensitively" do
    assert [%DetectedQuestion{prompt: "Should we rebase?", options: ["yes", "no"]}] =
             detect_questions("[question: Should we rebase?] [options: yes, no]")
  end

  test "allows leading whitespace, blockquotes, and bullet markers" do
    assert [%DetectedQuestion{prompt: "Bullet question"}] = detect_questions("- [QUESTION: Bullet question]")
    assert [%DetectedQuestion{prompt: "Star bullet question"}] = detect_questions("* [QUESTION: Star bullet question]")
    assert [%DetectedQuestion{prompt: "Blockquote question"}] = detect_questions("> [QUESTION: Blockquote question]")

    assert [%DetectedQuestion{prompt: "Nested prefix question"}] =
             detect_questions("  > * -  [QUESTION: Nested prefix question]")
  end

  test "ignores question marker quoted mid-sentence in prose" do
    assert detect_questions("The user asked [QUESTION: what about this?] earlier in the discussion.") == []
  end

  test "rejects placeholder prompts echoing role brief templates" do
    assert detect_questions("[QUESTION: <question>]") == []
    assert detect_questions("[QUESTION: <describe your question here>]") == []
    assert detect_questions("[QUESTION: ...]") == []
    assert detect_questions("[QUESTION: …]") == []
    assert detect_questions("[QUESTION:   . . .   ]") == []
    assert detect_questions("[QUESTION: ]") == []
    assert detect_questions("[QUESTION:    ]") == []
  end

  test "returns an empty list when there is nothing to ask" do
    assert detect_questions(nil) == []
    assert detect_questions("") == []
    assert detect_questions("   ") == []
    assert detect_questions("Just prose.") == []
  end

  test "returns every question in order, collapsing repeats" do
    text = """
    Looking at the schema.
    [QUESTION: Which database?] [OPTIONS: PG, MySQL]
    Some prose in between.
    > [QUESTION: Ship behind a flag?]
    [QUESTION: <placeholder>]
    [QUESTION: which database?]
    """

    assert [
             %DetectedQuestion{prompt: "Which database?", options: ["PG", "MySQL"]},
             %DetectedQuestion{prompt: "Ship behind a flag?", options: []}
           ] = detect_questions(text)
  end
end
