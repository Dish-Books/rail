defmodule Rail.Pipeline.Schemas.PlanCommentCaptureTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.PlanCommentCapture

  @mark "<!-- Rail cut the element's HTML here, at 20,000 characters. -->"

  test "HTML past 20,000 characters is cut there with Rail's mark" do
    html = "<div>" <> String.duplicate("é", 20_000) <> "</div>"

    cut = String.slice(html, 0, 20_000) <> @mark
    changeset = PlanCommentCapture.changeset(%PlanCommentCapture{}, %{html: html, width: 300, height: 40})

    assert %PlanCommentCapture{html: ^cut} = Ecto.Changeset.apply_action!(changeset, :insert)
  end

  test "HTML of 20,000 characters or fewer is kept whole, as is HTML the overlay already cut" do
    whole = String.duplicate("a", 20_000)
    already_cut = String.duplicate("b", 20_000) <> @mark

    for html <- [whole, already_cut, "<button>Answer</button>"] do
      changeset = PlanCommentCapture.changeset(%PlanCommentCapture{}, %{html: html, width: 1, height: 1})
      assert %PlanCommentCapture{html: ^html} = Ecto.Changeset.apply_action!(changeset, :insert)
    end
  end

  test "a box that is not a positive whole size is refused" do
    for {width, height} <- [{0, 10}, {10, -1}, {12.5, 10}, {"wide", 10}] do
      changeset = PlanCommentCapture.changeset(%PlanCommentCapture{}, %{html: "<p>x</p>", width: width, height: height})
      refute changeset.valid?
    end
  end

  test "a capture needs its HTML and its box" do
    assert %{html: ["can't be blank"], width: ["can't be blank"], height: ["can't be blank"]} =
             errors_on(PlanCommentCapture.changeset(%PlanCommentCapture{}, %{}))
  end
end
