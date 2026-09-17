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
end
