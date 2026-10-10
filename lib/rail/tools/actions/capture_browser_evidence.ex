defmodule Rail.Tools.Actions.CaptureBrowserEvidence do
  @moduledoc """
  Saves a screenshot of the browser in the task's QA folder under a name Rail chooses, so no path arrives
  from outside; a finding that cites the path attaches a copy. A screen state's shot goes in that state's
  own folder, named for when it was taken, so its shots sort oldest first.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.BrowserSession

  @doc """
  Captures the page as `name`, or as a shot of the screen state `key`, and returns `{:ok, path}` relative
  to the task's QA folder, which is what a finding's evidence cites.
  """
  def capture_browser_evidence(session, %Task{scratch_path: scratch_path}, name, key \\ nil) do
    with {:ok, %{"data" => data}} <-
           BrowserSession.call(session, "Page.captureScreenshot", %{format: "jpeg", quality: 72}),
         {:ok, bytes} <- Base.decode64(data) do
      file =
        if key,
          do: "screens/#{slug(key)}/#{System.os_time(:microsecond)}.jpg",
          else: "shots/#{slug(name)}-#{System.unique_integer([:positive])}.jpg"

      path = Path.join([scratch_path, "qa", file])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)

      {:ok, file}
    else
      :error -> {:error, :unreadable_screenshot}
      {:error, reason} -> {:error, reason}
    end
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
