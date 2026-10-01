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

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "", role_name: "Product")

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

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "Staging", role_name: "Product")

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

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "", role_name: "Product")

    refute html =~ ~s(data-qa="question-context-summary")
  end

  test "omits option chips when options list is empty" do
    question = %Question{
      id: "qst_empty_opts",
      prompt: "Provide custom API token",
      options: []
    }

    html =
      render_component(&AnswerField.answer_field/1, question: question, answer_text: "secret_123", role_name: "Product")

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

    html =
      render_component(&CoreComponents.answer_field/1, question: question, answer_text: "Option A", role_name: "Product")

    assert html =~ "Map prompt text"
    assert html =~ "Map summary"
    assert html =~ "Option A"

    nil_html = render_component(&AnswerField.answer_field/1, question: nil, role_name: "Product")
    assert nil_html =~ ~s(data-qa="answer-field")
  end

  test "renders one tab per pending question and marks the selected one" do
    questions = [
      %Question{id: "qst_1", prompt: "Which database?", options: []},
      %Question{id: "qst_2", prompt: "Ship behind a flag?", options: []},
      %Question{id: "qst_3", prompt: "Who reviews it?", options: []}
    ]

    html =
      render_component(&AnswerField.answer_field/1,
        question: Enum.at(questions, 1),
        questions: questions,
        answer_text: "",
        role_name: "Product"
      )

    assert html =~ ~s(data-qa="question-tabs")
    assert html =~ ~s(data-qa="question-tab-0")
    assert html =~ ~s(data-qa="question-tab-2")
    assert html =~ "3 still to answer"

    # The card body shows the selected tab's question, not the first.
    assert html =~ "Ship behind a flag?"
    assert html =~ ~s(phx-value-question_id="qst_2")

    [_before, from_selected_tab] = String.split(html, ~s(data-qa="question-tab-1"), parts: 2)
    assert from_selected_tab =~ ~s(aria-selected="true")
  end

  test "a lone question renders no tab strip" do
    question = %Question{id: "qst_1", prompt: "Which database?", options: []}

    html = render_component(&AnswerField.answer_field/1, question: question, answer_text: "", role_name: "Product")

    refute html =~ ~s(data-qa="question-tabs")
  end

  describe "a round with saved answers" do
    setup do
      questions = [
        %Question{id: "qst_1", prompt: "Which database?", status: :answered, answer: "Postgres", options: []},
        %Question{id: "qst_2", prompt: "Ship behind a flag?", status: :pending, options: []},
        %Question{id: "qst_3", prompt: "Who reviews it?", status: :pending, options: []}
      ]

      %{questions: questions}
    end

    test "each tab says where its question stands, and the footer counts what is open", %{questions: questions} do
      html =
        render_component(&AnswerField.answer_field/1,
          question: Enum.at(questions, 1),
          questions: questions,
          role_name: "Product"
        )

      assert html =~ ~s(aria-label="Question 1, answered")
      assert html =~ ~s(aria-label="Question 2, not answered yet")
      assert html =~ ~s(aria-label="Question 3, not answered yet")
      assert html =~ "Not answered yet"
      assert html =~ "2 still to answer"
      refute html =~ "unanswered"
    end

    test "an answered question shows its saved answer and offers to change it", %{questions: questions} do
      html =
        render_component(&AnswerField.answer_field/1,
          question: Enum.at(questions, 0),
          questions: questions,
          role_name: "Product"
        )

      assert html =~ "Answered · not sent yet"
      assert html =~ ~s(data-qa="saved-answer")
      assert html =~ "Postgres"
      assert html =~ ~s(id="change-answer-button")
      assert html =~ ~s(id="dismiss-question-button")
      refute html =~ ~s(id="answer-textarea")
    end

    test "changing an answer opens the form filled with it, with Cancel instead of Dismiss", %{
      questions: questions
    } do
      html =
        render_component(&AnswerField.answer_field/1,
          question: Enum.at(questions, 0),
          questions: questions,
          answer_text: "Postgres",
          changing_answer: true,
          role_name: "Product"
        )

      assert html =~ "Answered · changing your answer"
      assert html =~ ~r/<textarea[^>]*id="answer-textarea"[^>]*>Postgres<\/textarea>/
      assert html =~ ~s(id="cancel-answer-button")
      refute html =~ ~s(id="dismiss-question-button")
      refute html =~ ~s(data-qa="saved-answer")
    end
  end

  test "a dismissed question in a mixed round says the agent carries on, and can be answered instead" do
    questions = [
      %Question{id: "qst_1", prompt: "Which database?", status: :answered, answer: "Postgres", options: []},
      %Question{id: "qst_2", prompt: "Ship behind a flag?", status: :dismissed, options: []}
    ]

    html =
      render_component(&AnswerField.answer_field/1,
        question: Enum.at(questions, 1),
        questions: questions,
        role_name: "Product"
      )

    assert html =~ ~s(aria-label="Question 2, dismissed")
    assert html =~ "Dismissed · not sent yet"
    assert html =~ ~s(data-qa="dismissed-note")
    assert html =~ "Product will carry on without an answer to this."
    assert html =~ ~s(id="answer-instead-button")
    refute html =~ ~s(id="answer-textarea")
    refute html =~ "still to answer"
    refute html =~ ~r/id="send-answers-button"[^>]*\sdisabled[\s>]/
  end

  test "a round with nothing open can be sent" do
    questions = [
      %Question{id: "qst_1", prompt: "Which database?", status: :answered, answer: "Postgres", options: []},
      %Question{id: "qst_2", prompt: "Ship behind a flag?", status: :answered, answer: "Yes", options: []}
    ]

    html =
      render_component(&AnswerField.answer_field/1, question: hd(questions), questions: questions, role_name: "Product")

    refute html =~ ~r/id="send-answers-button"[^>]*\sdisabled[\s>]/
    refute html =~ ~s(id="dismiss-questions-button")
  end

  test "a round still open cannot be sent" do
    question = %Question{id: "qst_1", prompt: "Which database?", status: :pending, options: []}

    html = render_component(&AnswerField.answer_field/1, question: question, questions: [question], role_name: "Product")

    assert html =~ ~r/id="send-answers-button"[^>]*\sdisabled[\s>]/
  end

  test "a round dismissed in full offers Dismiss questions instead of Send answers" do
    questions = [
      %Question{id: "qst_1", prompt: "Which database?", status: :dismissed, options: []},
      %Question{id: "qst_2", prompt: "Ship behind a flag?", status: :dismissed, options: []}
    ]

    html =
      render_component(&AnswerField.answer_field/1, question: hd(questions), questions: questions, role_name: "Product")

    assert html =~ ~s(id="dismiss-questions-button")
    refute html =~ ~s(id="send-answers-button")
    assert html =~ "Every question in this round is dismissed, so Product won&#39;t get a message about it."
    refute html =~ "not sent yet"
  end

  test "answering a dismissed question instead opens the form with Cancel" do
    questions = [
      %Question{id: "qst_1", prompt: "Which database?", status: :answered, answer: "Postgres", options: []},
      %Question{id: "qst_2", prompt: "Ship behind a flag?", status: :dismissed, options: []}
    ]

    html =
      render_component(&AnswerField.answer_field/1,
        question: Enum.at(questions, 1),
        questions: questions,
        changing_answer: true,
        role_name: "Product"
      )

    assert html =~ ~s(id="answer-textarea")
    assert html =~ ~s(id="cancel-answer-button")
    refute html =~ ~s(data-qa="dismissed-note")
  end
end
