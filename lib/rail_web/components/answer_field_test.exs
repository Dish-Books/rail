defmodule RailWeb.Components.AnswerFieldTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Question
  alias RailWeb.Components.AnswerField
  alias RailWeb.CoreComponents

  setup do
    by_rail = %Question{
      id: "qst_1",
      prompt: "Which database?",
      status: :answered,
      answer: "Postgres",
      answered_by_rail: true,
      options: ["Postgres", "SQLite"]
    }

    open = %Question{id: "qst_2", prompt: "Ship behind a flag?", status: :pending, options: []}
    answered = %Question{id: "qst_3", prompt: "Who reviews it?", status: :answered, answer: "Sam", options: []}
    dismissed = %Question{id: "qst_4", prompt: "Which region?", status: :dismissed, options: ["eu", "us"]}

    source = %{
      answer: "Yes, behind a flag.",
      by: "Mara Lind",
      identifier: "RAIL-33",
      task_id: "tsk_33",
      date: ~U[2026-09-28 10:00:00Z]
    }

    %{
      round: [by_rail, open, answered, dismissed],
      suggestions: %{"qst_1" => %{source | by: "Dan Okafor", identifier: "RAIL-31", task_id: "tsk_31"}, "qst_2" => source}
    }
  end

  test "each chip carries its number and says where its question stands", %{round: round, suggestions: suggestions} do
    html = render_component(&AnswerField.answer_field/1, question: hd(round), questions: round, suggestions: suggestions)

    assert html =~ ~r/id="question-tab-0"[^>]*aria-label="Question 1, answered by Rail"/
    assert html =~ ~r/id="question-tab-1"[^>]*aria-label="Question 2, not answered yet"/
    assert html =~ ~r/id="question-tab-2"[^>]*aria-label="Question 3, answered"/
    assert html =~ ~r/id="question-tab-3"[^>]*aria-label="Question 4, dismissed"/
    assert html |> Floki.parse_fragment!() |> Floki.find("#question-tab-3") |> Floki.text() =~ "4"
  end

  test "the line under the prompt says whose answer the box holds, and a person's own needs none", %{
    round: [by_rail, open, answered, dismissed] = round,
    suggestions: suggestions
  } do
    meta = fn question, suggestions ->
      (&AnswerField.answer_field/1)
      |> render_component(question: question, questions: round, suggestions: suggestions, answer_text: "")
      |> Floki.parse_fragment!()
      |> Floki.find("#question-meta")
    end

    assert by_rail |> meta.(suggestions) |> Floki.text() =~ ~r/Rail answered from Dan Okafor on\s*RAIL-31, Sep 28/
    assert by_rail |> meta.(suggestions) |> Floki.find("a") |> Floki.attribute("href") == ["/tasks/tsk_31"]
    assert by_rail |> meta.(%{}) |> Floki.text() =~ "Rail answered from a past answer"
    assert open |> meta.(suggestions) |> Floki.text() =~ ~r/Likely answer, from Mara Lind on\s*RAIL-33, Sep 28/

    unlinked = %{"qst_2" => %{suggestions["qst_2"] | identifier: nil, task_id: nil}}
    assert open |> meta.(unlinked) |> Floki.text() =~ "Likely answer, from Mara Lind, Sep 28"

    elsewhere = %{"qst_2" => %{suggestions["qst_2"] | task_id: nil}}
    assert open |> meta.(elsewhere) |> Floki.find("a") == []
    assert open |> meta.(elsewhere) |> Floki.text() =~ "RAIL-33"

    assert dismissed |> meta.(suggestions) |> Floki.text() =~ "Dismissed"
    assert meta.(answered, suggestions) == []
    assert meta.(open, %{}) == []
  end

  test "an open question holding its likely answer keeps Send answers away though every other is answered", %{
    round: [by_rail, open, answered, _dismissed],
    suggestions: suggestions
  } do
    html =
      render_component(&AnswerField.answer_field/1,
        question: open,
        questions: [by_rail, open, answered],
        suggestions: suggestions,
        answer_text: "Yes, behind a flag."
      )

    assert html =~ "Likely answer"
    assert html =~ "Yes, behind a flag."
    refute html =~ ~s(id="send-answers-button")
    assert html =~ ~s(id="dismiss-question-button")
  end

  test "only a question's first option is marked Recommended, and one without options has none", %{round: round} do
    html = render_component(&AnswerField.answer_field/1, question: hd(round), questions: round, answer_text: "Postgres")
    options = Floki.parse_fragment!(html)

    assert options |> Floki.find("#question-option-0 [data-qa='recommended']") |> Floki.text() =~ "Recommended"
    assert Floki.find(options, "#question-option-1 [data-qa='recommended']") == []
    assert Floki.find(options, "#question-option-0.bg-blue-100") != []

    bare = render_component(&AnswerField.answer_field/1, question: Enum.at(round, 1), questions: round)
    refute bare =~ ~s(data-qa="recommended")
    refute bare =~ ~s(id="question-options")
  end

  test "Send answers shows only once nothing is open and the box holds nothing unsaved", %{
    round: [by_rail, open, answered, dismissed]
  } do
    render = fn question, questions, text ->
      render_component(&AnswerField.answer_field/1, question: question, questions: questions, answer_text: text)
    end

    with_open = render.(open, [by_rail, open, answered], "")
    assert with_open =~ ~s(id="dismiss-question-button")
    refute with_open =~ ~s(id="send-answers-button")

    settled = render.(answered, [by_rail, answered, dismissed], "Sam")
    assert settled =~ ~s(id="dismiss-question-button")
    assert settled =~ ~s(id="send-answers-button")
    refute settled =~ ~s(id="dismiss-questions-button")

    refute render.(answered, [by_rail, answered, dismissed], "Dana") =~ ~s(id="send-answers-button")
  end

  test "a round dismissed in full offers Dismiss questions in Send's place, held back by an unsaved edit", %{
    round: [_by_rail, _open, _answered, dismissed]
  } do
    other = %{dismissed | id: "qst_5", prompt: "Which team?"}
    html = render_component(&AnswerField.answer_field/1, question: dismissed, questions: [dismissed, other])

    assert html =~ ~s(id="dismiss-questions-button")
    refute html =~ ~s(id="send-answers-button")
    refute html =~ ~s(id="dismiss-question-button")

    typed =
      render_component(&AnswerField.answer_field/1, question: dismissed, questions: [dismissed, other], answer_text: "eu")

    refute typed =~ ~s(id="dismiss-questions-button")
  end

  test "the card has one box and none of the old answer cards, notes or buttons", %{
    round: round,
    suggestions: suggestions
  } do
    for question <- round do
      html =
        render_component(&AnswerField.answer_field/1, question: question, questions: round, suggestions: suggestions)

      assert html =~ ~s(id="answer-textarea")
      assert html =~ ~s(id="save-answer-button")

      for gone <- [
            "question-context-summary",
            "rail-answer",
            "likely-answer",
            "use-likely-answer",
            "answer-myself",
            "change-answer-button",
            "cancel-answer-button",
            "answer-instead-button",
            "questions-pending-note",
            "Asked during"
          ] do
        refute html =~ gone
      end
    end
  end

  test "a lone question still has its chip, which holds Dismiss and Send answers beside it" do
    question = %Question{id: "qst_lone", prompt: "Which database?", status: :answered, answer: "Postgres"}

    html =
      render_component(&AnswerField.answer_field/1, question: question, questions: [question], answer_text: "Postgres")

    assert [_one] = html |> Floki.parse_fragment!() |> Floki.find("#question-tabs [role='tab']")
    assert html =~ ~s(id="send-answers-button")
  end

  test "renders through CoreComponents from a bare map that has no status yet" do
    question = %{id: "qst_map_1", prompt: "Map prompt text", options: ["Option A"]}

    html = render_component(&CoreComponents.answer_field/1, question: question, answer_text: "Option A")

    assert html =~ "Map prompt text"
    assert html =~ "Option A"
    assert html =~ ~s(aria-label="Question 1, not answered yet")

    assert render_component(&AnswerField.answer_field/1, question: nil) =~ ~s(id="answer-textarea")
  end

  test "every chip, button and the form send to the target they are given, and to the page without one", %{
    round: [by_rail, open, answered, dismissed]
  } do
    rounds = [
      [question: open, questions: [by_rail, open]],
      [question: answered, questions: [by_rail, answered], answer_text: "Sam"],
      [question: dismissed, questions: [dismissed]]
    ]

    targeted =
      Enum.flat_map(rounds, fn round ->
        (&AnswerField.answer_field/1)
        |> render_component([target: "#question-card"] ++ round)
        |> Floki.parse_fragment!()
        |> Floki.find("[phx-click], [phx-submit]")
      end)

    assert targeted |> Enum.flat_map(&Floki.attribute(&1, "phx-target")) |> Enum.uniq() == ["#question-card"]
    assert length(Floki.attribute(targeted, "phx-target")) == length(targeted)

    assert targeted
           |> Enum.flat_map(&(Floki.attribute(&1, "phx-click") ++ Floki.attribute(&1, "phx-submit")))
           |> Enum.uniq()
           |> Enum.sort() ==
             [
               "answer_question",
               "dismiss_question",
               "dismiss_round",
               "select_option",
               "select_question",
               "send_answers"
             ]

    for round <- rounds do
      refute render_component(&AnswerField.answer_field/1, round) =~ "phx-target"
    end
  end

  test "the chip strip scrolls sideways only, and keeps the selected chip in view", %{round: round} do
    html = render_component(&AnswerField.answer_field/1, question: hd(round), questions: round)

    assert html =~ ~r/id="question-tabs"[^>]*phx-hook="ScrollSelectedTab"/
    assert html =~ ~r/id="question-tabs"[^>]*class="[^"]*overflow-x-auto overflow-y-hidden/
  end
end
