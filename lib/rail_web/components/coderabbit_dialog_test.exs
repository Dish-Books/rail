defmodule RailWeb.Components.CoderabbitDialogTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.CoderabbitReview
  alias Rail.Pipeline.Schemas.Task
  alias RailWeb.Components.CoderabbitDialog

  test "a pull request's first review reads it whole, from the reader's account, and says Finalize gives way to Review" do
    doc =
      (&CoderabbitDialog.coderabbit_dialog/1)
      |> render_component(task: %Task{stage: :finalize, pr_number: 77}, reviews: [], login: "dana")
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#coderabbit-title") |> Floki.text() =~ "Ask CodeRabbit to review PR #77?"
    assert doc |> Floki.find("#coderabbit-comment") |> Floki.text() =~ "your GitHub account, dana"
    assert doc |> Floki.find("#coderabbit-comment") |> Floki.text() =~ "@coderabbitai full review"
    assert doc |> Floki.find("#coderabbit-spend") |> Floki.text() =~ "first CodeRabbit review"
    assert [_finalize] = Floki.find(doc, "#coderabbit-finalize")
    assert [] = Floki.find(doc, "#confirm-coderabbit[disabled]")
  end

  test "after a finished review it asks only for the commits since, and counts what came before" do
    done = %CoderabbitReview{status: :done}

    for {reviews, said} <- [
          {[done], "It has had 1 review before this one."},
          {[done, %CoderabbitReview{status: :rate_limited}], "It has had 2 reviews before this one."}
        ] do
      doc =
        (&CoderabbitDialog.coderabbit_dialog/1)
        |> render_component(task: %Task{stage: :review, pr_number: 77}, reviews: reviews)
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("#coderabbit-comment") |> Floki.text() =~ "@coderabbitai review"
      refute doc |> Floki.find("#coderabbit-comment") |> Floki.text() =~ "your GitHub account,"
      assert doc |> Floki.find("#coderabbit-spend") |> Floki.text() =~ said
      assert [] = Floki.find(doc, "#coderabbit-finalize")
    end
  end

  test "while a review is waiting it says so and Ask CodeRabbit cannot be clicked" do
    doc =
      (&CoderabbitDialog.coderabbit_dialog/1)
      |> render_component(task: %Task{stage: :review, pr_number: 77}, reviews: [%CoderabbitReview{status: :reviewing}])
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#coderabbit-waiting") |> Floki.text() =~ "already reviewing"
    assert [] = Floki.find(doc, "#coderabbit-comment")
    assert [_disabled] = Floki.find(doc, "#confirm-coderabbit[disabled]")
  end
end
