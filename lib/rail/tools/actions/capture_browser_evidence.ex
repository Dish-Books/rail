defmodule Rail.Tools.Actions.CaptureBrowserEvidence do
  @moduledoc """
  Takes a screenshot of what the browser is looking at and files it under the task.

  Rail chooses the filename. The caller says what the picture is of and which
  check it belongs to, and gets back the name to cite, which means no path ever
  arrives from outside and nothing has to be validated on the way in or the way
  out. The findings that reference these are read by a person in the panel long
  after the pass has ended, so they live in the task's scratch rather than
  anywhere the run controls.

  The check's key leads the filename, because a picture is evidence for one row
  of the checklist and the panel shows it against that row. `~` separates them:
  a slug cannot contain one and neither can a key, so the name comes apart again
  without anything having recorded where to cut it.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.BrowserSession

  @doc """
  Captures the page as `name`, against the check `key`, and returns `{:ok, path}`
  relative to the task's QA directory - which is exactly what a finding's
  evidence should carry.
  """
  def capture_browser_evidence(session, %Task{scratch_path: scratch_path}, name, key \\ nil) do
    file = "evidence/#{prefix(key)}#{slug(name)}.jpg"
    path = Path.join([scratch_path, "qa", file])

    with {:ok, %{"data" => data}} <-
           BrowserSession.call(session, "Page.captureScreenshot", %{format: "jpeg", quality: 72}),
         {:ok, bytes} <- Base.decode64(data) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)

      {:ok, file}
    else
      :error -> {:error, :unreadable_screenshot}
      {:error, reason} -> {:error, reason}
    end
  end

  # A pass that files a picture before it has a checklist still gets a name; it
  # just belongs to no row.
  defp prefix(nil), do: ""
  defp prefix(key), do: "#{slug(key)}~"

  # A caption becomes a filename, so it is reduced to something a filesystem and
  # a URL both accept. Two shots described the same way would collide, which is
  # why the name carries enough of the caption to tell them apart.
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> then(fn slug -> if slug == "", do: "shot", else: slug end)
  end
end
