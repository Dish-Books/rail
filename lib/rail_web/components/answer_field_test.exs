defmodule RailWeb.Components.AnswerFieldTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Question
  alias RailWeb.Components.AnswerField
  alias RailWeb.CoreComponents

  test "renders question prompt, context summary, and option chips" do
    question = %Question{
      id: "qst_123",
      prompt: "Should we migrate to PostgreSQL or stay with SQLite?",
      context_summary: "Found conflicting database configs in repo",
      options: ["PostgreSQL", "SQLite", "Other"]
    }

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "")

    assert html =~ ~s(data-qa="answer-field")
    assert html =~ ~s(data-qa="question-prompt")
    assert html =~ "Should we migrate to PostgreSQL or stay with SQLite?"
    assert html =~ ~s(data-qa="question-context-summary")
    assert html =~ "Found conflicting database configs in repo"
    assert html =~ ~s(data-qa="question-options")
    assert html =~ ~s(data-qa="question-option-0")
    assert html =~ "PostgreSQL"
    assert html =~ ~s(data-qa="question-option-1")
    assert html =~ "SQLite"
    assert html =~ ~s(data-qa="question-option-2")
    assert html =~ "Other"
    assert html =~ ~s(data-qa="answer-textarea")
    assert html =~ ~s(data-qa="dismiss-question-button")
    assert html =~ ~s(data-qa="answer-resume-button")
  end

  test "highlights active option chip matching answer_text" do
    question = %Question{
      id: "qst_456",
      prompt: "Select environment",
      options: ["Staging", "Production"]
    }

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "Staging")

    assert html =~ "bg-blue-100 dark:bg-blue-900 text-blue-800 dark:text-blue-200"
    assert html =~ "Staging"
  end

  test "omits context summary when blank or nil" do
    question = %Question{
      id: "qst_789",
      prompt: "Continue deployment?",
      context_summary: nil,
      options: ["Yes", "No"]
    }

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "")

    refute html =~ ~s(data-qa="question-context-summary")
  end

  test "omits option chips when options list is empty" do
    question = %Question{
      id: "qst_empty_opts",
      prompt: "Provide custom API token",
      options: []
    }

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "secret_123")

    refute html =~ ~s(data-qa="question-options")
    assert html =~ "secret_123"
  end

  test "renders properly via CoreComponents.answer_field delegation with map input and handles nil question" do
    question = %{
      id: "qst_map_1",
      prompt: "Map prompt text",
      context_summary: "Map summary",
      options: ["Option A"]
    }

    html = render_component(&CoreComponents.answer_field/1, question: question, answer_text: "Option A")

    assert html =~ "Map prompt text"
    assert html =~ "Map summary"
    assert html =~ "Option A"

    nil_html = render_component(&AnswerField.answer_field/1, question: nil)
    assert nil_html =~ ~s(data-qa="answer-field")
  end
end
