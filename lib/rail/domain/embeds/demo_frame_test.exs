defmodule Rail.Domain.Embeds.DemoFrameTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Embeds.DemoFrame

  test "changeset/2 validates required url and positive hold_ms" do
    changeset = DemoFrame.changeset(%DemoFrame{}, %{})
    refute changeset.valid?
    assert %{url: ["can't be blank"]} = errors_on(changeset)

    invalid_hold = DemoFrame.changeset(%DemoFrame{}, %{"url" => "https://foo.png", "hold_ms" => 0})
    refute invalid_hold.valid?
    assert %{hold_ms: ["must be greater than 0"]} = errors_on(invalid_hold)

    valid =
      DemoFrame.changeset(%DemoFrame{}, %{
        "url" => "https://foo.png",
        "caption" => "Step 1"
      })

    assert valid.valid?
    assert Ecto.Changeset.get_field(valid, :hold_ms) == 1000
  end

  test "serializes to JSON" do
    frame = %DemoFrame{url: "https://linear.app/assets/frame_1.png", linear_asset_id: "asset_f1", hold_ms: 1000, caption: "Sign-in screen displayed"}
    assert {:ok, json} = Jason.encode(frame)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["url"] == "https://linear.app/assets/frame_1.png"
    assert decoded["hold_ms"] == 1000
  end
end
