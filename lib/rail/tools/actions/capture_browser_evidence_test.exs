defmodule Rail.Tools.Actions.CaptureBrowserEvidenceTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  setup %{project: project} do
    scope = system_scope()

    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_cpe_1", "identifier" => "CPE-1", "title" => "Capture Evidence"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(scope, project, %{description: "Capture Evidence"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  # Rail names the file from the caption, so nothing arriving from a model ever becomes a path.
  test "a caption becomes the filename under shots, and the caller is told which", %{task: task} do
    stub_screenshot(page_png(:empty_list))

    assert {:ok, "shots/the-bill-total-as-rendered-" <> _unique = file} =
             Tools.capture_browser_evidence(:session, task, "The bill total, as rendered")

    assert String.ends_with?(file, ".jpg")
    assert File.read!(Path.join([task.scratch_path, "qa", file])) == "jpeg bytes"
  end

  test "a screen state's shot goes in that state's folder, named for when it was taken", %{task: task} do
    stub_screenshot(page_png(:empty_list))

    assert {:ok, "screens/file-list-after-send/" <> stamp} =
             Tools.capture_browser_evidence(:session, task, "File list just after Send", key: "file-list-after-send")

    assert {_microseconds, ".jpg"} = Integer.parse(stamp)
  end

  # Two pictures with one caption are two pictures, so neither writes over the other.
  test "the same caption twice saves two files", %{task: task} do
    stub_screenshot(page_png(:empty_list))

    {:ok, first} = Tools.capture_browser_evidence(:session, task, "The saved bill")
    {:ok, second} = Tools.capture_browser_evidence(:session, task, "The saved bill")

    assert first != second
    assert [_first, _second] = Path.wildcard(Path.join([task.scratch_path, "qa", "shots", "*.jpg"]))
  end

  # A caption with nothing a filesystem would keep still has to land somewhere.
  test "a caption made of nothing a filename can hold still saves", %{task: task} do
    stub_screenshot(page_png(:empty_list))

    assert {:ok, "shots/shot-" <> _unique} = Tools.capture_browser_evidence(:session, task, "!!!")
  end

  # A tab still on about:blank, or a page that has not painted, is no picture of anything.
  test "a picture all one color is refused and nothing is saved", %{task: task} do
    stub_screenshot(page_png(:flat))

    assert {:error, :flat_screenshot} = Tools.capture_browser_evidence(:session, task, "The bill")

    assert {:error, :flat_screenshot} =
             Tools.capture_browser_evidence(:session, task, "File list", key: "file-list-after-send")

    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))
    refute File.exists?(Path.join([task.scratch_path, "qa", "screens"]))
  end

  # Flat is about color, never about how much is on the page.
  test "an empty list with only its nothing-here line is saved on the first take", %{task: task} do
    stub_screenshot(page_png(:empty_list))

    assert {:ok, "screens/learnings-empty/" <> _stamp = file} =
             Tools.capture_browser_evidence(:session, task, "Learnings with nothing to review", key: "learnings-empty")

    assert File.exists?(Path.join([task.scratch_path, "qa", file]))
  end

  test "a width is set before the page settles and cleared once the picture is saved", %{task: task} do
    test = self()

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", params ->
        send(test, {:cdp, "Page.getLayoutMetrics", params})

        {:ok, %{"cssLayoutViewport" => %{"pageX" => 0, "pageY" => 1200, "clientWidth" => 1009, "clientHeight" => 1080}}}

      _session, "Page.captureScreenshot", %{format: "png"} = params ->
        send(test, {:cdp, "Page.captureScreenshot", params})
        {:ok, %{"data" => Base.encode64(page_png(:empty_list))}}

      _session, method, params ->
        send(test, {:cdp, method, params})
        {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    assert {:ok, "shots/at-1024-" <> _unique} = Tools.capture_browser_evidence(:session, task, "At 1024", width: 1024)

    clip = %{x: 0, y: 1200, width: 1009, height: 1080, scale: 1}

    assert {:messages,
            [
              {:cdp, "Emulation.setDeviceMetricsOverride",
               %{width: 1024, height: 1080, deviceScaleFactor: 1, mobile: false}},
              {:cdp, "Runtime.evaluate", %{awaitPromise: true}},
              {:cdp, "Page.getLayoutMetrics", %{}},
              {:cdp, "Page.captureScreenshot", %{format: "png", clip: ^clip}},
              {:cdp, "Page.captureScreenshot", %{format: "jpeg", clip: ^clip}},
              {:cdp, "Emulation.clearDeviceMetricsOverride", %{}}
            ]} = Process.info(self(), :messages)
  end

  # A refused picture must not leave the tab narrow for the explorer's next script.
  test "a narrow width is laid out as a phone and cleared also when the picture is refused", %{task: task} do
    test = self()

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params ->
        {:ok, %{"cssLayoutViewport" => %{"pageX" => 0, "pageY" => 0, "clientWidth" => 600, "clientHeight" => 1080}}}

      _session, "Page.captureScreenshot", %{format: "png"} ->
        {:ok, %{"data" => Base.encode64(page_png(:flat))}}

      _session, method, params ->
        send(test, {:cdp, method, params})
        {:ok, %{}}
    end)

    assert {:error, :flat_screenshot} = Tools.capture_browser_evidence(:session, task, "At 600", width: 600)

    assert {:messages,
            [
              {:cdp, "Emulation.setDeviceMetricsOverride", %{width: 600, mobile: true}},
              {:cdp, "Runtime.evaluate", _settle},
              {:cdp, "Emulation.clearDeviceMetricsOverride", %{}}
            ]} = Process.info(self(), :messages)
  end

  # The explorer's own resize may still be live on its script's connection, and is its own to keep.
  test "with no width the tab's size is left alone", %{task: task} do
    test = self()

    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params ->
        {:ok, %{"cssLayoutViewport" => %{"pageX" => 0, "pageY" => 0, "clientWidth" => 1920, "clientHeight" => 1080}}}

      _session, "Page.captureScreenshot", %{format: "png"} ->
        {:ok, %{"data" => Base.encode64(page_png(:empty_list))}}

      _session, method, _params ->
        send(test, {:cdp, method})
        {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    assert {:ok, _file} = Tools.capture_browser_evidence(:session, task, "At the window's width")

    assert {:messages, [{:cdp, "Runtime.evaluate"}, {:cdp, "Page.captureScreenshot"}]} = Process.info(self(), :messages)
  end

  # Chrome picks a filter per row, and a row read through the wrong one would make a flat picture look busy.
  test "a picture is judged by its pixels whatever filter each row was written with", %{task: task} do
    chunk = fn type, data -> <<byte_size(data)::32, type::binary, data::binary, :erlang.crc32(type <> data)::32>> end

    # Two RGBA pixels a row, written as is, from the left, from the average of left and above, and by Paeth,
    # whose last row takes the pixel above and to the left. All 9 give or take 4, but for `second`.
    for {second, flat?} <- [{9, true}, {13, true}, {14, false}] do
      rows = [
        <<0, 9, 9, 9, 255, second, second, second, 255>>,
        <<1, 9, 9, 9, 255, 0, 0, 0, 0>>,
        <<3, 5, 5, 5, 128, 0, 0, 0, 0>>,
        <<4, 0, 0, 0, 0, 0, 0, 0, 0>>,
        <<0, 9, 9, 9, 255, 5, 5, 5, 255>>,
        <<4, 4, 4, 4, 0, 0, 0, 0, 0>>
      ]

      png =
        <<137, "PNG", 13, 10, 26, 10>> <>
          chunk.("IHDR", <<2::32, 6::32, 8, 6, 0, 0, 0>>) <>
          chunk.("tEXt", "Software\0Chrome") <>
          chunk.("IDAT", :zlib.compress(rows)) <> chunk.("IEND", "")

      stub_screenshot(png)

      assert match?({:error, :flat_screenshot}, Tools.capture_browser_evidence(:session, task, "Rows")) == flat?
    end
  end

  test "a picture that is not a PNG Rail can read is not saved", %{task: task} do
    grey = <<137, "PNG", 13, 10, 26, 10, 13::32, "IHDR", 1::32, 1::32, 8, 0, 0, 0, 0, 0::32, 0::32, "IEND", 0::32>>

    for png <- ["jpeg bytes", grey, <<137, "PNG", 13, 10, 26, 10, 99::32, "IHDR">>] do
      stub_screenshot(png)

      assert {:error, :unreadable_screenshot} = Tools.capture_browser_evidence(:session, task, "The bill")
    end

    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))
  end

  test "a screenshot that is not readable is not saved", %{task: task} do
    stub(BrowserSession, :call, fn
      _session, "Page.getLayoutMetrics", _params ->
        {:ok, %{"cssLayoutViewport" => %{"pageX" => 0, "pageY" => 0, "clientWidth" => 1920, "clientHeight" => 1080}}}

      _session, _method, _params ->
        {:ok, %{"data" => "not base64 at all!"}}
    end)

    assert {:error, :unreadable_screenshot} = Tools.capture_browser_evidence(:session, task, "The bill")
    refute File.exists?(Path.join([task.scratch_path, "qa", "shots"]))
  end

  test "a browser that refuses to photograph says why", %{task: task} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:error, "Not attached to an active page"} end)

    assert {:error, "Not attached to an active page"} = Tools.capture_browser_evidence(:session, task, "The bill")
    assert {:error, "Not attached to an active page"} = Tools.capture_browser_evidence(:session, task, "Bill", width: 800)
  end
end
