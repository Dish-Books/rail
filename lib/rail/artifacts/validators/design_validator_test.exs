defmodule Rail.Artifacts.Validators.DesignValidatorTest do
  use ExUnit.Case, async: true

  alias Rail.Artifacts.Validators.DesignValidator
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_design_validator"

  setup do
    dir = Path.join(@tmp_base, "design_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "validate/2" do
    test "returns error when manifest does not exist", %{dir: dir} do
      assert {:error, msg} = DesignValidator.validate(dir)
      assert msg =~ "No design manifest found"
    end

    test "returns error when manifest is invalid JSON or not object", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), "{invalid_json")
      assert {:error, msg} = DesignValidator.validate(dir)
      assert msg =~ "Failed to parse design manifest"

      File.write!(Path.join(dir, "manifest.json"), ~s(["not", "object"]))
      assert {:error, msg2} = DesignValidator.validate(dir)
      assert msg2 =~ "Invalid design manifest: expected a JSON object"
    end

    test "validates canvasUrl required and absolute https", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"version" => 1}))
      assert {:error, msg} = DesignValidator.validate(dir)
      assert msg =~ "Design manifest is missing a canvasUrl"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"canvasUrl" => "http://insecure.com"})
      )

      assert {:error, msg2} = DesignValidator.validate(dir)
      assert msg2 =~ "canvasUrl must be an absolute https URL"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"canvasUrl" => "not_a_url"})
      )

      assert {:error, msg3} = DesignValidator.validate(dir)
      assert msg3 =~ "canvasUrl must be an absolute https URL"
    end

    test "validates directions non-empty and valid objects", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/1",
          "directions" => []
        })
      )

      assert {:error, msg} = DesignValidator.validate(dir)
      assert msg =~ "must contain at least one design direction"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/1",
          "directions" => ["not_object"]
        })
      )

      assert {:error, msg2} = DesignValidator.validate(dir)
      assert msg2 =~ "Invalid direction entry in design manifest: expected an object"
    end

    test "validates required direction fields", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/1",
          "directions" => [%{"key" => "k1", "title" => "T1"}]
        })
      )

      assert {:error, msg} = DesignValidator.validate(dir)
      assert msg =~ "Direction entry missing required fields (key, title, notes, stillPath)"
    end

    test "validates still_path confinement and existence", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/1",
          "directions" => [
            %{
              "key" => "k1",
              "title" => "T1",
              "notes" => "N1",
              "still_path" => "../escaped.png"
            }
          ]
        })
      )

      assert {:error, esc_err} = DesignValidator.validate(dir)
      assert esc_err =~ "Design still image path must stay inside design directory"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "canvasUrl" => "https://canvas.example.com/1",
          "directions" => [
            %{
              "key" => "k1",
              "title" => "T1",
              "notes" => "N1",
              "still_path" => "missing.png"
            }
          ]
        })
      )

      assert {:error, exist_err} = DesignValidator.validate(dir)
      assert exist_err =~ "Design still image not found or empty"
    end

    test "canvas URL probe failure returns error", %{dir: dir} do
      ArtifactHelpers.write_design_manifest(dir)

      failing_probe = fn _url -> false end
      assert {:error, probe_err} = DesignValidator.validate(dir, url_probe: failing_probe)
      assert probe_err =~ "Canvas URL could not be opened or returned 404/410"
    end

    test "valid design manifest with successful probe returns success", %{dir: dir} do
      ArtifactHelpers.write_design_manifest(dir, %{"version" => 2.0})

      passing_probe = fn _url -> true end
      expanded_dir = Path.expand(dir)

      assert {:ok,
              %{
                version: 2,
                canvas_url: "https://canvas.example.com/project/abc",
                picked_key: "dir_a",
                directions: [
                  %{
                    key: "dir_a",
                    title: "Direction A",
                    notes: "Minimalist card layout",
                    still_path: still_path
                  }
                ]
              }} = DesignValidator.validate(dir, url_probe: passing_probe)

      assert String.starts_with?(still_path, expanded_dir)
    end

    test "handles non-string canvasUrl and fallback version", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"canvasUrl" => 12_345})
      )

      assert {:error, msg} = DesignValidator.validate(dir)
      assert msg =~ "Design manifest is missing a canvasUrl"

      ArtifactHelpers.write_design_manifest(dir)
      manifest = dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(Map.put(manifest, "version", "invalid")))

      assert {:ok, %{version: 1}} = DesignValidator.validate(dir, url_probe: fn _url -> true end)
    end
  end
end
