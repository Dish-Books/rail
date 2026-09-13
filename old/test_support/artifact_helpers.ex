defmodule RailTest.Support.ArtifactHelpers do
  @moduledoc false

  @doc "Creates a scratch directory structure for testing."
  def setup_scratch_dir(base_dir, kind) do
    dir = Path.join([base_dir, "scratch", to_string(kind)])
    File.mkdir_p!(dir)
    dir
  end

  @doc "Writes a non-empty dummy image file at path."
  def write_dummy_image(path, content \\ "PNG_IMAGE_DATA") do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    File.write!(path, content)
    path
  end

  @doc "Writes a valid demo manifest in the demo directory."
  def write_demo_manifest(demo_dir, attrs \\ %{}) do
    frame_path = "ac1-0.png"
    write_dummy_image(Path.join(demo_dir, frame_path))

    default_data = %{
      "outcome" => "recorded",
      "version" => 1,
      "segments" => [
        %{
          "criterionIndex" => 1,
          "criterion" => "User can view task",
          "outcome" => "recorded",
          "frames" => [
            %{
              "path" => frame_path,
              "holdMs" => 1000,
              "caption" => "Viewing task screen"
            }
          ]
        }
      ]
    }

    data = Map.merge(default_data, attrs)
    manifest_file = Path.join(demo_dir, "manifest.json")
    File.write!(manifest_file, Jason.encode!(data))
    manifest_file
  end

  @doc "Writes a valid design manifest in the design directory."
  def write_design_manifest(design_dir, attrs \\ %{}) do
    still_filename = "still_a.png"
    write_dummy_image(Path.join(design_dir, still_filename))

    default_data = %{
      "version" => 1,
      "canvasUrl" => "https://canvas.example.com/project/abc",
      "pickedKey" => "dir_a",
      "directions" => [
        %{
          "key" => "dir_a",
          "title" => "Direction A",
          "notes" => "Minimalist card layout",
          "still_path" => still_filename
        }
      ]
    }

    data = Map.merge(default_data, attrs)
    manifest_file = Path.join(design_dir, "manifest.json")
    File.write!(manifest_file, Jason.encode!(data))
    manifest_file
  end

  @doc "Writes a valid QA manifest in the qa directory."
  def write_qa_manifest(qa_dir, attrs \\ %{}) do
    screenshot_path = Path.join(qa_dir, "screenshot.png")
    write_dummy_image(screenshot_path)

    default_data = %{
      "commit" => "abc1234",
      "session" => %{"port" => 4000, "url" => "http://localhost:4000"},
      "rows" => [
        %{
          "id" => "check_1",
          "check" => "Login works",
          "result" => "pass",
          "severity" => "blocker",
          "caused_by_change" => true,
          "command" => "mix test",
          "exit_code" => 0,
          "note" => "Passed cleanly",
          "artifacts" => [
            %{
              "name" => "screenshot.png",
              "kind" => "image",
              "path" => "screenshot.png"
            }
          ]
        }
      ]
    }

    data = Map.merge(default_data, attrs)
    manifest_file = Path.join(qa_dir, "manifest.json")
    File.write!(manifest_file, Jason.encode!(data))
    manifest_file
  end
end
