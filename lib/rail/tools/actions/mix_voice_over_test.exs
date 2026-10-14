defmodule Rail.Tools.Actions.MixVoiceOverTest do
  use Rail.DataCase, async: true

  alias Rail.Tools

  # ffmpeg is the edge, so what is tested is the track handed to it and what each answer becomes.
  setup do
    directory = Path.join([System.tmp_dir!(), "rail_mix_test", to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(Path.join(directory, "narration"))
    File.write!(Path.join(directory, "demo.webm"), "silent")
    # Clips of 10 ms and 20 ms: 48 bytes a millisecond.
    File.write!(Path.join([directory, "narration", "0.pcm"]), :binary.copy(<<1>>, 480))
    File.write!(Path.join([directory, "narration", "1.pcm"]), :binary.copy(<<2>>, 960))
    on_exit(fn -> File.rm_rf(directory) end)
    %{directory: directory, video: Path.join(directory, "demo.webm")}
  end

  test "lays each clip where its caption plays and muxes the track into the video, keeping its picture", %{
    directory: directory,
    video: video
  } do
    track = Path.join(directory, "narration.pcm")
    voiced = Path.join(directory, "demo.voiced.webm")

    expect(Tools, :run, fn "ffmpeg", argv, [stderr_to_stdout: true] ->
      assert ["-y", "-i", ^video, "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", ^track | rest] = argv
      assert ["-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "libopus", "-b:a", "64k", ^voiced] = rest
      File.write!(voiced, "voiced")
      {"", 0}
    end)

    assert {:ok, ^video} = Tools.mix_voice_over(directory, [5, 30])
    assert File.read!(video) == "voiced"

    # 5 ms of silence, the first clip to 15 ms, silence to 30 ms, then the second.
    assert File.read!(track) ==
             :binary.copy(<<0>>, 240) <> :binary.copy(<<1>>, 480) <> :binary.copy(<<0>>, 720) <> :binary.copy(<<2>>, 960)
  end

  test "a clip whose caption plays before the one ahead has finished waits for it", %{directory: directory} do
    stub(Tools, :run, fn "ffmpeg", _argv, _opts ->
      File.write!(Path.join(directory, "demo.voiced.webm"), "voiced")
      {"", 0}
    end)

    assert {:ok, _video} = Tools.mix_voice_over(directory, [0, 4])
    assert File.read!(Path.join(directory, "narration.pcm")) == :binary.copy(<<1>>, 480) <> :binary.copy(<<2>>, 960)
  end

  test "an ffmpeg that refused, or none at all, leaves the silent video as it was", %{
    directory: directory,
    video: video
  } do
    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"Unknown encoder 'libopus'\n", 1} end)
    assert {:error, {:encode_failed, "Unknown encoder 'libopus'"}} = Tools.mix_voice_over(directory, [0, 30])

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> raise ErlangError, original: :enoent end)
    assert {:error, :no_ffmpeg} = Tools.mix_voice_over(directory, [0, 30])
    assert File.read!(video) == "silent"
  end
end
