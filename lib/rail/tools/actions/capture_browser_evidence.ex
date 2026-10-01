defmodule Rail.Tools.Actions.CaptureBrowserEvidence do
  @moduledoc """
  Takes a screenshot of what the browser is looking at and files it under the task.

  Rail chooses the filename. The caller says what the picture is of and which
  check it belongs to, and gets back the name to cite, which means no path ever
  arrives from outside and nothing has to be validated on the way in or the way
  out. The findings that reference these are read by a person in the panel long
  after the pass has ended, so they live in the task's scratch rather than
  anywhere the run controls.
  """

  import Rail.Tools.Utils.WriteQaEvidence

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Tools.BrowserSession

  @doc """
  Captures the page as `name`, against the check `key`, and returns `{:ok, path}`
  relative to the task's QA directory - which is exactly what a finding's
  evidence should carry.
  """
  def capture_browser_evidence(session, %Task{scratch_path: scratch_path}, name, key \\ nil) do
    with {:ok, %{"data" => data}} <-
           BrowserSession.call(session, "Page.captureScreenshot", %{format: "jpeg", quality: 72}),
         {:ok, bytes} <- Base.decode64(data) do
      {:ok, write_qa_evidence(scratch_path, name, key, ".jpg", &File.write!(&1, bytes))}
    else
      :error -> {:error, :unreadable_screenshot}
      {:error, reason} -> {:error, reason}
    end
  end
end
