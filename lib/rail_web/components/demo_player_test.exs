defmodule RailWeb.Components.DemoPlayerTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Pipeline.Schemas.Demo
  alias Rail.Pipeline.Schemas.DemoBeat
  alias RailWeb.Components.DemoPlayer

  @task %{id: "tsk_demo_player"}
  @beat %DemoBeat{at_ms: 1_000, text: "Open the task", criterion: nil}

  test "a recording counts the beats it has said" do
    for {beats, said} <- [
          {[@beat], "Recording · 1 beat said so far"},
          {[@beat, @beat], "Recording · 2 beats said so far"}
        ] do
      doc =
        (&DemoPlayer.demo_player/1)
        |> render_component(task: @task, beats: beats, recorded: false, recording: true)
        |> Floki.parse_fragment!()

      assert ^said = doc |> Floki.find("[data-qa=review_demo_header]") |> Floki.text() |> String.trim()
    end
  end

  test "a demo saved without a commit reads Recorded, and says what it did not show" do
    demo = %Demo{title: "Send once", summary: "Sends once.", not_shown: "The Slack post", commit: nil}

    doc =
      (&DemoPlayer.demo_player/1)
      |> render_component(task: @task, demo: demo, beats: [@beat], recorded: true, recording: false)
      |> Floki.parse_fragment!()

    assert "Recorded" = doc |> Floki.find("[data-qa=review_demo_header]") |> Floki.text() |> String.trim()
    assert doc |> Floki.find("[data-qa=demo_not_shown]") |> Floki.text() =~ "Not shown: The Slack post"
  end
end
