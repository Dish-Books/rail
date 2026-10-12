defmodule RailWeb.Components.AnswersCardTest do
  use RailWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Question
  alias RailWeb.CoreComponents

  setup do
    items = [
      %{question: %Question{prompt: "Which database?", status: :answered, answer: "Postgres"}, citation: nil},
      %{
        question: %Question{prompt: "Behind a flag?", status: :answered, answer: "Yes.", answered_by_rail: true},
        citation: %{by: "Dan Okafor", identifier: "RAIL-31", date: "Oct 2"}
      },
      %{question: %Question{prompt: "Who reviews it?", status: :answered, answer: "Sam"}, citation: nil},
      %{question: %Question{prompt: "Which region?", status: :dismissed}, citation: nil}
    ]

    %{items: items}
  end

  test "a person's round lists each question in order with its answer, the dismissed one marked", %{items: items} do
    html = render_component(&CoreComponents.answers_card/1, id: "msg-3", sender: "Dana", from: :person, items: items)
    card = Floki.parse_fragment!(html)

    assert [_card] = Floki.find(card, "#msg-3[data-qa='answers-card'][data-from='person']")
    assert html =~ "Dana"
    assert html =~ "answers to 4 questions"

    assert ["Which database?", "Behind a flag?", "Who reviews it?", "Which region?"] =
             card |> Floki.find("[data-qa='answers-card-item'] p[title]") |> Floki.attribute("title")

    assert [dismissed] = Floki.find(card, "[data-qa='answers-card-dismissed']")
    assert Floki.text(dismissed) =~ "Dismissed"
  end

  test "a Rail answer in a person's round carries its citation, linking its issue", %{items: items} do
    card =
      (&CoreComponents.answers_card/1)
      |> render_component(id: "msg-3", sender: "Dana", from: :person, items: items)
      |> Floki.parse_fragment!()

    assert [citation] = Floki.find(card, "[data-qa='answers-card-citation']")
    assert citation |> Floki.text() |> String.split() |> Enum.join(" ") == "Rail, from Dan Okafor on RAIL-31, Oct 2"
    assert Floki.attribute(citation, "a", "href") == ["/issues/RAIL-31"]
  end

  test "Rail's round reads apart from a person's and cites each answer, or a past answer where it named none" do
    items = [
      %{
        question: %Question{prompt: "Wait for the turn?", status: :answered, answer: "Yes", answered_by_rail: true},
        citation: %{by: "Mara Lind", identifier: "RAIL-33", date: "Sep 28"}
      },
      %{
        question: %Question{prompt: "Count on Send?", status: :answered, answer: "Yes", answered_by_rail: true},
        citation: %{by: "Dan Okafor", identifier: nil, date: "Oct 4"}
      },
      %{
        question: %Question{prompt: "Group by file?", status: :answered, answer: "Yes", answered_by_rail: true},
        citation: nil
      }
    ]

    html = render_component(&CoreComponents.answers_card/1, id: "msg-5", sender: "Rail", from: :rail, items: items)
    card = Floki.parse_fragment!(html)

    assert [_card] = Floki.find(card, "[data-qa='answers-card'][data-from='rail']")
    assert html =~ "answered 3 questions from past answers"
    assert html =~ "border-dashed"

    assert ["From Mara Lind on RAIL-33, Sep 28", "From Dan Okafor, Oct 4", "From a past answer"] =
             card
             |> Floki.find("[data-qa='answers-card-citation']")
             |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))

    assert Floki.attribute(card, "[data-qa='answers-card-citation'] a", "href") == ["/issues/RAIL-33"]

    one = render_component(&CoreComponents.answers_card/1, id: "msg-6", sender: "Rail", from: :rail, items: [hd(items)])
    assert one =~ "answered 1 question from a past answer"

    lone =
      render_component(&CoreComponents.answers_card/1, id: "msg-7", sender: "Dana", from: :person, items: [hd(items)])

    assert lone =~ "answer to 1 question"
  end
end
