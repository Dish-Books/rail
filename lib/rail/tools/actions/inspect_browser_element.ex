defmodule Rail.Tools.Actions.InspectBrowserElement do
  @moduledoc """
  Says which element of a tab is under a point, the way a design comment names one, and photographs it.

  The selector is in the grammar `assets/js/hooks/design_frame.js` builds and resolves: the nearest plain unique id,
  then `tag:nth-child(n)` steps, so a comment on the app reads like one on a design and can be found again.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools
  alias Rail.Tools.BrowserSession

  # Mirrors buildSelector, elementText and captureElement in assets/js/hooks/design_frame.js.
  @describe """
  ((x, y) => {
    const PLAIN_ID = /^[A-Za-z][A-Za-z0-9_-]*$/
    const UNSEEN = new Set(["script", "style", "template", "noscript"])
    const element = document.elementFromPoint(x, y)
    if (!element) return null
    const selector = []
    let node = element
    while (node) {
      if (PLAIN_ID.test(node.id || "") && document.querySelectorAll("[id='" + node.id + "']").length === 1) {
        selector.unshift("#" + node.id)
        break
      }
      const parent = node.parentElement
      if (!parent) { selector.unshift(node.localName); break }
      selector.unshift(node.localName + ":nth-child(" + (Array.prototype.indexOf.call(parent.children, node) + 1) + ")")
      node = parent
    }
    const seen = n => n.nodeType === 3 ? n.data : UNSEEN.has(n.localName) ? "" : Array.from(n.childNodes || [], seen).join("")
    const text = typeof element.innerText === "string" ? element.innerText : seen(element)
    const box = element.getBoundingClientRect()
    return {
      selector: selector.join(" > ").slice(0, 1000),
      text: text.split(/\\s+/).filter(Boolean).join(" ").slice(0, 200),
      tag: element.localName.slice(0, 64),
      html: (element.outerHTML || "").slice(0, 20000),
      x: Math.round(box.left), y: Math.round(box.top),
      width: Math.max(1, Math.round(box.width)), height: Math.max(1, Math.round(box.height)),
      url: location.href
    }
  })
  """

  @viewport {1920, 1080}

  @doc """
  Describes the element at `x`, `y` in the browser `name` on `task` and saves a picture of it under `dir`. Returns
  `{:ok, %{selector:, text:, tag:, html:, x:, y:, width:, height:, url:, picture:}}`, with `picture` the saved file's
  path, or `{:error, :no_element}`, `{:error, :no_browser}` or what Chrome said.
  """
  def inspect_browser_element(%Task{} = task, name, x, y, dir) when is_number(x) and is_number(y) do
    expression = "#{@describe}(#{x}, #{y})"

    with pid when is_pid(pid) <- Tools.get_browser_session(task, name) || {:error, :no_browser},
         {:ok, %{"result" => %{"value" => %{} = element}}} <-
           BrowserSession.call(pid, "Runtime.evaluate", %{expression: expression, returnByValue: true}),
         {:ok, %{"data" => data}} <- BrowserSession.call(pid, "Page.captureScreenshot", screenshot(element)) do
      picture = Path.join(dir, "#{UXID.generate!(prefix: "elm")}.jpg")
      File.mkdir_p!(dir)
      File.write!(picture, Base.decode64!(data))

      {:ok,
       %{
         selector: element["selector"],
         text: element["text"],
         tag: element["tag"],
         html: element["html"],
         x: element["x"],
         y: element["y"],
         width: element["width"],
         height: element["height"],
         url: element["url"],
         picture: picture
       }}
    else
      {:ok, %{"result" => _nothing_there}} -> {:error, :no_element}
      {:error, reason} -> {:error, reason}
    end
  end

  # The element and a margin round it, kept inside the viewport, since a picture is of what a person could see.
  defp screenshot(%{"x" => x, "y" => y, "width" => width, "height" => height}) do
    {viewport_width, viewport_height} = @viewport
    left = max(x - 16, 0)
    top = max(y - 16, 0)
    right = min(x + width + 16, viewport_width)
    bottom = min(y + height + 16, viewport_height)

    %{
      format: "jpeg",
      quality: 85,
      clip: %{x: left, y: top, width: max(right - left, 1), height: max(bottom - top, 1), scale: 1}
    }
  end
end
