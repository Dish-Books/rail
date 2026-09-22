defmodule Rail.Pipeline.Actions.ListDemoBeatsTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.DemoBeat
  alias Rail.Pipeline.Schemas.Task

  setup do
    scratch = Path.join([System.tmp_dir!(), "rail_beats_test", to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(Path.join(scratch, "demo"))
    on_exit(fn -> File.rm_rf(scratch) end)

    %{task: %Task{scratch_path: scratch}, captions: Path.join([scratch, "demo", "captions.jsonl"])}
  end

  test "lists every beat in the order it plays", %{task: task, captions: captions} do
    File.write!(captions, """
    {"at_ms": 4200, "text": "Entering a bill", "criterion": "A bill can be entered"}
    {"at_ms": 0, "text": "Starting on the bills page", "criterion": null}
    """)

    assert [
             %DemoBeat{at_ms: 0, recorded_ms: 0, text: "Starting on the bills page", criterion: nil},
             %DemoBeat{at_ms: 4200, recorded_ms: 4200, text: "Entering a bill", criterion: "A bill can be entered"}
           ] = Pipeline.list_demo_beats(task)
  end

  # Once the video is encoded, where a caption plays is not where it was said:
  # the encode squeezed out the time nothing happened. The player wants the first.
  test "a beat plays where the video put it, and remembers where it was said", %{task: task, captions: captions} do
    File.write!(captions, ~s({"at_ms": 95000, "video_ms": 31000, "text": "Saved exactly as entered"}\n))

    assert [%DemoBeat{at_ms: 31_000, recorded_ms: 95_000}] = Pipeline.list_demo_beats(task)
  end

  test "a run that has narrated nothing yet has no beats", %{task: task} do
    assert Pipeline.list_demo_beats(task) == []
  end

  # Appended while the run works, so its last line can be half written when the
  # recording stops.
  test "a half-written line is one beat short rather than a crash", %{task: task, captions: captions} do
    File.write!(captions, """
    {"at_ms": 0, "text": "Starting"}
    {"at_ms": 900, "te
    """)

    assert [%DemoBeat{text: "Starting"}] = Pipeline.list_demo_beats(task)
  end

  test "a beat with no criterion is getting from one place to another", %{task: task, captions: captions} do
    File.write!(captions, ~s({"at_ms": 0, "text": "Signing in", "criterion": "  "}\n))

    assert [%DemoBeat{criterion: nil}] = Pipeline.list_demo_beats(task)
  end
end
