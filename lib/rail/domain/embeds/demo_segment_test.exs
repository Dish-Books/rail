defmodule Rail.Domain.Embeds.DemoSegmentTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Embeds.DemoFrame
  alias Rail.Domain.Embeds.DemoSegment

  test "factory/0 builds a valid struct with embedded frame" do
    segment = DemoSegment.factory()
    assert segment.criterion_index == 1
    assert segment.criterion == "User can sign in with GitHub"
    assert segment.outcome == :recorded
    assert [%DemoFrame{url: "https://linear.app/assets/frame_1.png"}] = segment.frames
  end

  test "changeset/2 validates required fields, index, and casts embedded frames" do
    changeset = DemoSegment.changeset(%DemoSegment{}, %{})
    refute changeset.valid?

    assert %{
             criterion_index: ["can't be blank"],
             criterion: ["can't be blank"]
           } = errors_on(changeset)

    invalid_index =
      DemoSegment.changeset(%DemoSegment{}, %{
        "criterion_index" => 0,
        "criterion" => "Test"
      })

    refute invalid_index.valid?
    assert %{criterion_index: ["must be greater than or equal to 1"]} = errors_on(invalid_index)

    valid_attrs = %{
      "criterion_index" => 2,
      "criterion" => "User can export data",
      "outcome" => "not_filmable",
      "note" => "Backend background job",
      "frames" => [
        %{"url" => "https://example.com/f1.png", "hold_ms" => 1500},
        %{"url" => "https://example.com/f2.png", "hold_ms" => 2000}
      ]
    }

    valid = DemoSegment.changeset(%DemoSegment{}, valid_attrs)
    assert valid.valid?
    assert Ecto.Changeset.get_field(valid, :outcome) == :not_filmable

    frames = Ecto.Changeset.get_field(valid, :frames)
    assert length(frames) == 2
  end

  test "duration_ms/1 sums frame hold times" do
    segment = %DemoSegment{
      frames: [
        %DemoFrame{url: "https://a.png", hold_ms: 1000},
        %DemoFrame{url: "https://b.png", hold_ms: 2500},
        %DemoFrame{url: "https://c.png", hold_ms: nil}
      ]
    }

    # 1000 + 2500 + 1000 (fallback for nil)
    assert DemoSegment.duration_ms(segment) == 4500

    assert DemoSegment.duration_ms(%DemoSegment{frames: []}) == 0
    assert DemoSegment.duration_ms(%DemoSegment{frames: nil}) == 0
    assert DemoSegment.duration_ms(%DemoSegment{}) == 0
  end

  test "serializes to JSON" do
    segment = DemoSegment.factory()
    assert {:ok, json} = Jason.encode(segment)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["criterion_index"] == 1
    assert [%{"url" => "https://linear.app/assets/frame_1.png"}] = decoded["frames"]
  end
end
