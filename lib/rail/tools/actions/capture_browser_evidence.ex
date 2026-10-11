defmodule Rail.Tools.Actions.CaptureBrowserEvidence do
  @moduledoc """
  Saves a screenshot of the browser in the task's QA folder under a name Rail chooses, so no path arrives
  from outside; a finding that cites the path attaches a copy. A screen state's shot goes in that state's
  own folder, named for when it was taken, so its shots sort oldest first.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.BrowserSession

  # Loaded, finite animations done and two frames painted, or two seconds, whichever comes first: a page
  # that never stops moving is photographed as it is.
  @settle """
  (async () => {
    const settled = (async () => {
      if (document.readyState !== 'complete') await new Promise((resolve) => addEventListener('load', resolve, { once: true }))
      const finite = document.getAnimations().filter((animation) =>
        animation.playState === 'running' && Number.isFinite(animation.effect?.getComputedTiming().endTime))
      await Promise.all(finite.map((animation) => animation.finished.catch(() => null)))
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))
    })()
    await Promise.race([settled, new Promise((resolve) => setTimeout(resolve, 2000))])
  })()
  """

  # Wide enough to absorb Chrome's PNG encoding, narrower than anything a page draws on purpose.
  @flat_within 4

  @doc """
  Captures the page as `name` and returns `{:ok, path}` relative to the task's QA folder, which is what a
  finding's evidence cites. `opts` takes the screen state's `:key` and the `:width` to lay the page out at.
  """
  def capture_browser_evidence(session, %Task{scratch_path: scratch_path}, name, opts \\ []) do
    width = opts[:width]

    # Two captures on one tab would each clear the other's width mid-picture.
    :global.trans({{:capture_browser_evidence, session}, self()}, fn ->
      with {:ok, _sized} <- size(session, width) do
        captured = capture(session, scratch_path, name, opts[:key])
        _cleared = unsize(session, width)
        captured
      end
    end)
  end

  # Set over Rail's own connection, since Chrome drops an override when the script that set it disconnects.
  defp size(_session, nil), do: {:ok, nil}

  defp size(session, width) do
    BrowserSession.call(session, "Emulation.setDeviceMetricsOverride", %{
      width: width,
      height: 1080,
      deviceScaleFactor: 1,
      mobile: width < 768
    })
  end

  defp unsize(_session, nil), do: {:ok, nil}
  defp unsize(session, _width), do: BrowserSession.call(session, "Emulation.clearDeviceMetricsOverride", %{})

  # Clipped to the viewport as laid out, so a page laid out narrower than the window fills the frame.
  defp capture(session, scratch_path, name, key) do
    with {:ok, _settled} <-
           BrowserSession.call(session, "Runtime.evaluate", %{
             expression: @settle,
             awaitPromise: true,
             returnByValue: true
           }),
         {:ok, %{"cssLayoutViewport" => viewport}} <- BrowserSession.call(session, "Page.getLayoutMetrics", %{}),
         clip = %{
           x: viewport["pageX"],
           y: viewport["pageY"],
           width: viewport["clientWidth"],
           height: viewport["clientHeight"],
           scale: 1
         },
         {:ok, %{"data" => png}} <- BrowserSession.call(session, "Page.captureScreenshot", %{format: "png", clip: clip}),
         {:ok, png} <- Base.decode64(png),
         false <- flat?(png),
         {:ok, %{"data" => jpeg}} <-
           BrowserSession.call(session, "Page.captureScreenshot", %{format: "jpeg", quality: 72, clip: clip}),
         {:ok, bytes} <- Base.decode64(jpeg) do
      file =
        if key,
          do: "screens/#{slug(key)}/#{System.os_time(:microsecond)}.jpg",
          else: "shots/#{slug(name)}-#{System.unique_integer([:positive])}.jpg"

      path = Path.join([scratch_path, "qa", file])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)

      {:ok, file}
    else
      true -> {:error, :flat_screenshot}
      :error -> {:error, :unreadable_screenshot}
      {:error, reason} -> {:error, reason}
    end
  end

  # Decoded only until a second color turns up, so a real page costs a row or two and only a flat one is read whole.
  defp flat?(png) do
    with <<137, "PNG", 13, 10, 26, 10, chunks::binary>> <- png,
         {:ok, width, channels, compressed} <- chunks(chunks, nil, []) do
      stride = width * channels
      flat_rows?(:zlib.uncompress(compressed), :binary.copy(<<0>>, stride), stride, channels, nil)
    else
      "" <> _not_png -> :error
      :error -> :error
    end
  end

  defp chunks(<<length::32, "IHDR", header::binary-size(length), _crc::32, rest::binary>>, _header, compressed),
    do: chunks(rest, header, compressed)

  defp chunks(<<length::32, "IDAT", data::binary-size(length), _crc::32, rest::binary>>, header, compressed),
    do: chunks(rest, header, [compressed, data])

  # Chrome writes 8-bit RGB, or RGBA where the page is see-through, never interlaced.
  defp chunks(<<_length::32, "IEND", _rest::binary>>, <<width::32, _height::32, 8, color, 0, 0, 0>>, compressed)
       when color in [2, 6], do: {:ok, width, if(color == 2, do: 3, else: 4), compressed}

  defp chunks(
         <<length::32, _ancillary::binary-size(4), _data::binary-size(length), _crc::32, rest::binary>>,
         header,
         compressed
       ), do: chunks(rest, header, compressed)

  defp chunks(_unreadable, _header, _compressed), do: :error

  defp flat_rows?(<<>>, _prior, _stride, _channels, _first), do: true

  defp flat_rows?(pixels, prior, stride, channels, first) do
    <<filter, line::binary-size(stride), rest::binary>> = pixels
    row = unfilter(filter, line, prior, channels, 0, <<>>)
    first = first || binary_part(row, 0, channels)

    near?(row, first) and flat_rows?(rest, row, stride, channels, first)
  end

  defp unfilter(0, line, _prior, _channels, _index, <<>>), do: line
  defp unfilter(_filter, <<>>, _prior, _channels, _index, row), do: row

  defp unfilter(filter, <<byte, rest::binary>>, prior, channels, index, row) do
    left = if index >= channels, do: :binary.at(row, index - channels), else: 0
    up = :binary.at(prior, index)
    up_left = if index >= channels, do: :binary.at(prior, index - channels), else: 0

    unfilter(
      filter,
      rest,
      prior,
      channels,
      index + 1,
      <<row::binary, rem(byte + predict(filter, left, up, up_left), 256)>>
    )
  end

  defp predict(1, left, _up, _up_left), do: left
  defp predict(2, _left, up, _up_left), do: up
  defp predict(3, left, up, _up_left), do: div(left + up, 2)

  defp predict(4, left, up, up_left) do
    estimate = left + up - up_left

    cond do
      abs(estimate - left) <= abs(estimate - up) and abs(estimate - left) <= abs(estimate - up_left) -> left
      abs(estimate - up) <= abs(estimate - up_left) -> up
      true -> up_left
    end
  end

  defp near?(<<>>, _first), do: true

  defp near?(row, first) do
    <<pixel::binary-size(byte_size(first)), rest::binary>> = row

    (pixel == first or
       pixel
       |> :binary.bin_to_list()
       |> Enum.zip(:binary.bin_to_list(first))
       |> Enum.all?(fn {channel, against} -> abs(channel - against) <= @flat_within end)) and near?(rest, first)
  end

  # A caption becomes a filename, so it is reduced to what a filesystem and a URL both accept.
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> then(fn slug -> if slug == "", do: "shot", else: slug end)
  end
end
