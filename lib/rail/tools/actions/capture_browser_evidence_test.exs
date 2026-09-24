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
    {:ok, task} = Pipeline.create_task(issue, :qa)
    on_exit(fn -> File.rm_rf(task.scratch_path) end)

    %{task: task}
  end

  # Rail names the file from the caption, so nothing arriving from a model ever
  # becomes a path.
  test "a caption becomes the filename, and the caller is told which", %{task: task} do
    stub(BrowserSession, :call, fn _session, "Page.captureScreenshot", _params ->
      {:ok, %{"data" => Base.encode64("jpeg bytes")}}
    end)

    assert {:ok, "evidence/the-bill-total-as-rendered.jpg"} =
             Tools.capture_browser_evidence(:session, task, "The bill total, as rendered")

    assert File.read!(Path.join([task.scratch_path, "qa", "evidence", "the-bill-total-as-rendered.jpg"])) ==
             "jpeg bytes"
  end

  # The row it belongs to leads the name, which is how the panel shows a picture
  # against the check it was taken for.
  test "the check it was taken for leads the filename", %{task: task} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:ok, %{"data" => Base.encode64("jpeg")}} end)

    assert {:ok, "evidence/bill-saves~the-saved-bill.jpg"} =
             Tools.capture_browser_evidence(:session, task, "The saved bill", "bill-saves")
  end

  # A caption with nothing a filesystem would keep still has to land somewhere,
  # because the finding that cites it is already written.
  test "a caption made of nothing a filename can hold still files", %{task: task} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:ok, %{"data" => Base.encode64("jpeg")}} end)

    assert {:ok, "evidence/shot.jpg"} = Tools.capture_browser_evidence(:session, task, "!!!")
  end

  test "a screenshot that is not readable is not filed", %{task: task} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:ok, %{"data" => "not base64 at all!"}} end)

    assert {:error, :unreadable_screenshot} = Tools.capture_browser_evidence(:session, task, "The bill")
    refute File.exists?(Path.join([task.scratch_path, "qa", "evidence"]))
  end

  test "a browser that refuses to photograph says why", %{task: task} do
    stub(BrowserSession, :call, fn _session, _method, _params -> {:error, "Not attached to an active page"} end)

    assert {:error, "Not attached to an active page"} = Tools.capture_browser_evidence(:session, task, "The bill")
  end
end
