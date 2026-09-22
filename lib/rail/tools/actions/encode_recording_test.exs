defmodule Rail.Tools.Actions.EncodeRecordingTest do
  use Rail.DataCase, async: true

  alias Rail.Tools

  # ffmpeg is the edge, and `Tools.run/3` is where Rail reaches it. What is worth
  # testing is the manifest handed over and what each answer is made of - running
  # the encoder would test ffmpeg, slowly.
  setup do
    directory = Path.join([System.tmp_dir!(), "rail_encode_test", to_string(System.unique_integer([:positive]))])
    File.mkdir_p!(Path.join(directory, "frames"))

    on_exit(fn -> File.rm_rf(directory) end)

    %{directory: directory}
  end

  test "holds each frame until the next one arrived, and lists the last twice", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jpg", "at_ms": 400}
    {"file": "000002.jpg", "at_ms": 900}
    """)

    video = Path.join(directory, "demo.webm")
    manifest = Path.join(directory, "frames.txt")

    expect(Tools, :run, fn "ffmpeg", argv, opts ->
      assert opts[:stderr_to_stdout]

      # Native 1920x1080 in, native out: a demo is watched to see the
      # application, and a downscale is what makes small text unreadable.
      assert argv ==
               ["-y", "-f", "concat", "-safe", "0", "-i", manifest] ++
                 ["-c:v", "libvpx-vp9", "-crf", "36", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p", video]

      refute Enum.any?(argv, &String.contains?(&1, "scale"))
      refute Enum.any?(argv, &String.contains?(&1, "drawtext"))

      {"", 0}
    end)

    assert {:ok, ^video, []} = Tools.encode_recording(directory)

    # The concat demuxer ignores the final entry's duration and flashes past the
    # last frame unless it is listed twice.
    assert File.read!(manifest) == """
           file 'frames/000000.jpg'
           duration 0.400
           file 'frames/000001.jpg'
           duration 0.500
           file 'frames/000002.jpg'
           duration 2.000
           file 'frames/000002.jpg'
           """
  end

  # A still page is squeezed down to what is worth watching, and where each
  # caption landed in the squeezed video comes back for the player to use.
  test "squeezes the still stretches and says where each caption landed", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jpg", "at_ms": 43400}
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, [0]} = Tools.encode_recording(directory, [{1_000, 4_000}])

    assert File.read!(Path.join(directory, "frames.txt")) =~ "file 'frames/000000.jpg'\nduration 4.000\n"
  end

  # Two frames in the same millisecond still have to hold for something, or
  # ffmpeg drops one and every timing behind it shifts.
  test "a frame with no time between it and the next still holds", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 120}
    {"file": "000001.jpg", "at_ms": 120}
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, []} = Tools.encode_recording(directory)
    assert File.read!(Path.join(directory, "frames.txt")) =~ "file 'frames/000000.jpg'\nduration 0.001\n"
  end

  # Nothing is handed to ffmpeg at all, because a recording nothing painted into
  # is not a video that failed to encode.
  test "a recording nothing ever painted into is not a video", %{directory: directory} do
    assert Tools.encode_recording(directory) == {:error, :nothing_recorded}
  end

  # The file is appended to while the browser paints, so its last line can be
  # half written when the recording stops.
  test "a half-written line is one frame short rather than a crash", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jp
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, []} = Tools.encode_recording(directory)
    refute File.read!(Path.join(directory, "frames.txt")) =~ "000001"
  end

  test "an encode ffmpeg refused says what it said", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), ~s({"file": "000000.jpg", "at_ms": 0}\n))

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"frames/000000.jpg: Invalid data found\n", 1} end)

    assert {:error, {:encode_failed, "frames/000000.jpg: Invalid data found"}} = Tools.encode_recording(directory)
  end

  # An executable nothing on the path matches is handed to the port bare and the
  # port raises. That is the one failure here about the machine rather than about
  # the recording, and it reads as itself so the panel can say to install ffmpeg.
  test "a machine with no ffmpeg says so rather than blaming the recording", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), ~s({"file": "000000.jpg", "at_ms": 0}\n))

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> raise ErlangError, original: :enoent end)

    assert Tools.encode_recording(directory) == {:error, :no_ffmpeg}
  end
end
