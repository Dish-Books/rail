defmodule Rail.Tools.Actions.ObserveBrowser do
  @moduledoc """
  Reads the page a session is on, in one go.

  Everything a decision needs comes back from a single evaluation: the visible
  controls with their accessible names and values, the visible text, and the
  guards that say whether any of it has moved since. Reading it in pieces would
  mean reading a page that changed halfway through, and a decision made against
  half of one state and half of another is a decision about a page that never
  existed.

  The script is compiled in rather than read at runtime: it is code, and a
  release should carry it the way it carries everything else.
  """

  alias Rail.Tools.BrowserSession

  @snapshot_path [__DIR__, "..", "..", "..", "..", "priv", "browser", "snapshot.js"] |> Path.join() |> Path.expand()
  @external_resource @snapshot_path
  @snapshot File.read!(@snapshot_path)

  @doc """
  Returns `{:ok, page}` for what `session` is looking at.

  `opts` takes `:screenshot` to capture the page as it was read, which is what
  evidence is made of. A document that is navigating has nothing to read and
  comes back as `{:error, :navigating}` - worth asking again in a moment, unlike
  anything else here.
  """
  def observe_browser(session, opts \\ []) do
    case BrowserSession.call(session, "Runtime.evaluate", %{expression: @snapshot, returnByValue: true}) do
      {:ok, %{"result" => %{"value" => page}}} when is_map(page) ->
        page = Map.put(page, "fingerprint", fingerprint(page))

        {:ok, screenshot(page, session, opts)}

      {:ok, _no_document} ->
        {:error, :navigating}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # What the reader would call the same page: where it is, what it says, and what
  # can be done to it. Two observations with the same fingerprint are the same
  # page however long apart they were taken.
  defp fingerprint(page) do
    page
    |> Map.take(["url", "text", "actions", "scroll"])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp screenshot(page, session, opts) do
    if Keyword.get(opts, :screenshot, false) do
      case BrowserSession.call(session, "Page.captureScreenshot", %{format: "jpeg", quality: 72}) do
        {:ok, %{"data" => data}} -> Map.put(page, "screenshot", data)
        {:error, _gone} -> page
      end
    else
      page
    end
  end
end
