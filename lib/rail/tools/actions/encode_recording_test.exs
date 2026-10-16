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

      # A frame of another size is fitted and padded, never stretched, so the video keeps one size.
      assert argv ==
               ["-y", "-f", "concat", "-safe", "0", "-i", manifest] ++
                 ["-vf", "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2"] ++
                 ["-c:v", "libvpx-vp9", "-crf", "36", "-b:v", "0", "-row-mt", "1", "-pix_fmt", "yuv420p", video]

      refute Enum.any?(argv, &String.contains?(&1, "drawtext"))

      {"", 0}
    end)

    assert {:ok, ^video, []} = Tools.encode_recording(directory, [], :reading)

    # The concat demuxer ignores the final entry's duration and flashes past the
    # last frame unless it is listed twice.
    assert File.read!(manifest) == """
           file 'frames/000000.jpg'
           duration 0.400
           file 'frames/000001.jpg'
           duration 0.500
           file 'frames/000002.jpg'
           duration 1.000
           file 'frames/000002.jpg'
           """
  end

  # A still page is squeezed to a second whether a caption is up or not, what was
  # filmed after the last caption was read is not encoded, and where each caption
  # landed in the squeezed video comes back for the player to use.
  test "squeezes the still stretches, drops the run past the last caption, and says where it landed", %{
    directory: directory
  } do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jpg", "at_ms": 8000}
    {"file": "000002.jpg", "at_ms": 8600}
    {"file": "000003.jpg", "at_ms": 9900}
    {"file": "000004.jpg", "at_ms": 30000}
    """)

    # A silent take is timed by its frames alone, so a cut changes nothing.
    File.write!(Path.join(directory, "cuts.jsonl"), ~s({"at_ms": 8100}\n))

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, [125]} = Tools.encode_recording(directory, [{1_000, 1_200}], :reading)

    assert File.read!(Path.join(directory, "frames.txt")) == """
           file 'frames/000000.jpg'
           duration 1.000
           file 'frames/000001.jpg'
           duration 0.600
           file 'frames/000002.jpg'
           duration 0.725
           file 'frames/000002.jpg'
           """
  end

  # A spinner paints all through a voiced take, so the lines and the page's actions decide what is kept: the line
  # starts as the click lands, seconds after its caption, and the time before is cut.
  test "a voiced take is cut by its lines and the actions the page reported", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jpg", "at_ms": 5100}
    """)

    File.write!(Path.join(directory, "actions.jsonl"), """
    {"kind": "click", "at_ms": 5000}
    {"kind": "ke
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, [1_000]} = Tools.encode_recording(directory, [{1_000, 1_000}], :spoken)

    assert File.read!(Path.join(directory, "frames.txt")) == """
           file 'frames/000000.jpg'
           duration 1.400
           file 'frames/000001.jpg'
           duration 2.400
           file 'frames/000001.jpg'
           """
  end

  # QA's beat 0: a line with nothing to click, then the recorder signs in as someone else before the next caption.
  test "a line with no action plays at its caption when the setup after it is cut", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jpg", "at_ms": 7300}
    {"file": "000002.jpg", "at_ms": 8800}
    {"file": "000003.jpg", "at_ms": 33200}
    """)

    File.write!(Path.join(directory, "cuts.jsonl"), ~s({"at_ms": 6000}\n))

    File.write!(Path.join(directory, "actions.jsonl"), """
    {"kind": "navigate", "at_ms": 7278}
    {"kind": "navigate", "at_ms": 8786}
    {"kind": "click", "at_ms": 33161}
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, [1_000, 5_420]} =
             Tools.encode_recording(directory, [{1_180, 3_420}, {29_152, 2_000}], :spoken)

    assert File.read!(Path.join(directory, "frames.txt")) == """
           file 'frames/000000.jpg'
           duration 5.420
           file 'frames/000002.jpg'
           duration 0.339
           file 'frames/000003.jpg'
           duration 2.661
           file 'frames/000003.jpg'
           """
  end

  # QA's beat 3: the recorder switched user 2.6 s after the upload, which is close enough to chain into the beat.
  test "setup cut right after a beat's action plays no silence", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jpg", "at_ms": 75100}
    {"file": "000002.jpg", "at_ms": 77700}
    {"file": "000003.jpg", "at_ms": 79200}
    {"file": "000004.jpg", "at_ms": 95600}
    """)

    File.write!(Path.join(directory, "cuts.jsonl"), ~s({"at_ms": 77000}\n))

    File.write!(Path.join(directory, "actions.jsonl"), """
    {"kind": "click", "at_ms": 75026}
    {"kind": "navigate", "at_ms": 77622}
    {"kind": "navigate", "at_ms": 79131}
    {"kind": "click", "at_ms": 95500}
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    # Line 3 runs from 1 s to 3 s in the video, and the next starts a second later.
    assert {:ok, _video, [1_000, 4_000]} =
             Tools.encode_recording(directory, [{74_000, 2_000}, {95_000, 1_500}], :spoken)

    assert File.read!(Path.join(directory, "frames.txt")) == """
           file 'frames/000000.jpg'
           duration 1.374
           file 'frames/000001.jpg'
           duration 2.626
           file 'frames/000003.jpg'
           duration 0.400
           file 'frames/000004.jpg'
           duration 2.400
           file 'frames/000004.jpg'
           """
  end

  test "a cut after the last caption leaves out every action after it", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jpg", "at_ms": 2100}
    {"file": "000002.jpg", "at_ms": 4100}
    """)

    File.write!(Path.join(directory, "cuts.jsonl"), ~s({"at_ms": 3000}\n))

    File.write!(Path.join(directory, "actions.jsonl"), """
    {"kind": "click", "at_ms": 2000}
    {"kind": "click", "at_ms": 4000}
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, [1_000]} = Tools.encode_recording(directory, [{1_000, 1_000}], :spoken)

    refute File.read!(Path.join(directory, "frames.txt")) =~ "000002"
  end

  # Two frames in the same millisecond still have to hold for something, or
  # ffmpeg drops one and every timing behind it shifts.
  test "a frame with no time between it and the next still holds", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 120}
    {"file": "000001.jpg", "at_ms": 120}
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, []} = Tools.encode_recording(directory, [], :reading)
    assert File.read!(Path.join(directory, "frames.txt")) =~ "file 'frames/000000.jpg'\nduration 0.001\n"
  end

  # Nothing is handed to ffmpeg at all, because a recording nothing painted into
  # is not a video that failed to encode.
  test "a recording nothing ever painted into is not a video", %{directory: directory} do
    assert Tools.encode_recording(directory, [], :reading) == {:error, :nothing_recorded}
  end

  # The file is appended to while the browser paints, so its last line can be
  # half written when the recording stops.
  test "a half-written line is one frame short rather than a crash", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), """
    {"file": "000000.jpg", "at_ms": 0}
    {"file": "000001.jp
    """)

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"", 0} end)

    assert {:ok, _video, []} = Tools.encode_recording(directory, [], :reading)
    refute File.read!(Path.join(directory, "frames.txt")) =~ "000001"
  end

  test "an encode ffmpeg refused says what it said", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), ~s({"file": "000000.jpg", "at_ms": 0}\n))

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> {"frames/000000.jpg: Invalid data found\n", 1} end)

    assert {:error, {:encode_failed, "frames/000000.jpg: Invalid data found"}} =
             Tools.encode_recording(directory, [], :reading)
  end

  # An executable nothing on the path matches is handed to the port bare and the
  # port raises. That is the one failure here about the machine rather than about
  # the recording, and it reads as itself so the panel can say to install ffmpeg.
  test "a machine with no ffmpeg says so rather than blaming the recording", %{directory: directory} do
    File.write!(Path.join(directory, "frames.jsonl"), ~s({"file": "000000.jpg", "at_ms": 0}\n))

    expect(Tools, :run, fn "ffmpeg", _argv, _opts -> raise ErlangError, original: :enoent end)

    assert Tools.encode_recording(directory, [], :reading) == {:error, :no_ffmpeg}
  end
end
