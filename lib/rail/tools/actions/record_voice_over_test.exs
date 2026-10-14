defmodule Rail.Tools.Actions.RecordVoiceOverTest do
  use Rail.DataCase, async: true

  alias Rail.Tools
  alias Rail.Tools.Clients.Speech

  setup do
    directory = Path.join([System.tmp_dir!(), "rail_voice_test", to_string(System.unique_integer([:positive]))])
    on_exit(fn -> File.rm_rf(directory) end)
    %{directory: directory}
  end

  # A second of 24 kHz 16-bit mono is 48,000 bytes.
  test "speaks each line into a clip of its own and says how long each runs", %{directory: directory} do
    stub(Speech, :synthesize, fn
      "Starting on the bills page" -> {:ok, :binary.copy(<<0>>, 48_000)}
      "Saved exactly as entered" -> {:ok, :binary.copy(<<0>>, 24_000)}
    end)

    assert {:ok, [1_000, 500]} =
             Tools.record_voice_over(directory, ["Starting on the bills page", "Saved exactly as entered"])

    assert byte_size(File.read!(Path.join([directory, "narration", "0.pcm"]))) == 48_000
    assert byte_size(File.read!(Path.join([directory, "narration", "1.pcm"]))) == 24_000
  end

  # Half a voice-over is worse than none, so a line that cannot be spoken leaves no clips at all.
  test "a line that cannot be spoken is the error, with no clips left behind", %{directory: directory} do
    stub(Speech, :synthesize, fn
      "First" -> {:ok, "pcm"}
      "Second" -> {:error, {:speech_error, 429, "slow down"}}
    end)

    assert {:error, {:speech_error, 429, "slow down"}} = Tools.record_voice_over(directory, ["First", "Second"])
    refute File.exists?(Path.join(directory, "narration"))
  end
end
