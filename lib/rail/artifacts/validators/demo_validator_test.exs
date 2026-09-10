defmodule Rail.Artifacts.Validators.DemoValidatorTest do
  use ExUnit.Case, async: true

  alias Rail.Artifacts.Validators.DemoValidator
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_demo_validator"

  setup do
    dir = Path.join(@tmp_base, "demo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "validate/2" do
    test "returns error when manifest does not exist", %{dir: dir} do
      assert {:error, msg} = DemoValidator.validate(dir)
      assert msg =~ "Demo manifest not found"
    end

    test "returns error when manifest is invalid JSON", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), "{invalid_json")
      assert {:error, msg} = DemoValidator.validate(dir)
      assert msg =~ "Failed to parse demo manifest"
    end

    test "returns error when manifest is not a JSON object", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), ~s(["not", "object"]))
      assert {:error, msg} = DemoValidator.validate(dir)
      assert msg =~ "Demo manifest must be a JSON object"
    end

    test "returns error when outcome is missing or invalid", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{}))
      assert {:error, msg} = DemoValidator.validate(dir)
      assert msg =~ "Manifest missing \"outcome\" field"

      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"outcome" => "bogus"}))
      assert {:error, msg2} = DemoValidator.validate(dir)
      assert msg2 =~ "Invalid demo outcome: \"bogus\""
    end

    test "declined demo requires note and rejects segments", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"outcome" => "declined"}))
      assert {:error, msg} = DemoValidator.validate(dir)
      assert msg =~ "A declined demo requires a non-empty note explaining why"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "outcome" => "declined",
          "note" => "Backend only",
          "segments" => [%{"criterion" => "Test"}]
        })
      )

      assert {:error, msg2} = DemoValidator.validate(dir)
      assert msg2 =~ "A declined demo must not contain segments"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"outcome" => "declined", "note" => "Backend only", "version" => 2})
      )

      assert {:ok, %{outcome: "declined", version: 2, note: "Backend only", segments: []}} =
               DemoValidator.validate(dir)
    end

    test "recorded demo requires non-empty segments", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"outcome" => "recorded", "segments" => []})
      )

      assert {:error, msg} = DemoValidator.validate(dir)
      assert msg =~ "A recorded demo requires a non-empty list of segments"
    end

    test "validates criteria count and text matching", %{dir: dir} do
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Wrong text",
            "outcome" => "recorded",
            "frames" => [%{"path" => "ac1-0.png", "holdMs" => 1000}]
          }
        ]
      })

      criteria = ["Expected text A", "Expected text B"]
      assert {:error, count_err} = DemoValidator.validate(dir, criteria: criteria)
      assert count_err =~ "Manifest contains 1 segments, but the ticket defines 2 acceptance criteria"

      criteria_one = ["Expected text A"]
      assert {:error, match_err} = DemoValidator.validate(dir, criteria: criteria_one)
      assert match_err =~ "Segment 1 criterion text does not match acceptance criterion 1"
    end

    test "validates segment criterionIndex and outcome", %{dir: dir} do
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 5,
            "criterion" => "User can view task",
            "outcome" => "recorded",
            "frames" => [%{"path" => "ac1-0.png", "holdMs" => 1000}]
          }
        ]
      })

      assert {:error, idx_err} = DemoValidator.validate(dir)
      assert idx_err =~ "Segment at index 0 has criterionIndex 5, expected 1"

      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "User can view task",
            "outcome" => "invalid_seg_outcome",
            "frames" => [%{"path" => "ac1-0.png", "holdMs" => 1000}]
          }
        ]
      })

      assert {:error, out_err} = DemoValidator.validate(dir)
      assert out_err =~ "Segment 1 has invalid outcome: \"invalid_seg_outcome\""
    end

    test "validates not_filmable segment requirements", %{dir: dir} do
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Background worker",
            "outcome" => "not_filmable"
          }
        ]
      })

      assert {:error, note_err} = DemoValidator.validate(dir)
      assert note_err =~ "Segment 1 (not_filmable) requires a note explaining why"

      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Background worker",
            "outcome" => "not_filmable",
            "note" => "Headless worker",
            "frames" => [%{"path" => "ac1-0.png"}]
          }
        ]
      })

      assert {:error, frames_err} = DemoValidator.validate(dir)
      assert frames_err =~ "Segment 1 (not_filmable) must not contain frames"
    end

    test "validates frames holdMs, existence, and empty check", %{dir: dir} do
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => [%{"path" => "ac1-0.png", "holdMs" => 100}]
          }
        ]
      })

      assert {:error, hold_err} = DemoValidator.validate(dir)
      assert hold_err =~ "holdMs (100) must be between 200 and 15000 ms"

      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => [%{"path" => "missing.png", "holdMs" => 1000}]
          }
        ]
      })

      assert {:error, exist_err} = DemoValidator.validate(dir)
      assert exist_err =~ "file does not exist: \"missing.png\""

      empty_path = Path.join(dir, "empty.png")
      File.write!(empty_path, "")

      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => [%{"path" => "empty.png", "holdMs" => 1000}]
          }
        ]
      })

      assert {:error, empty_err} = DemoValidator.validate(dir)
      assert empty_err =~ "file is empty: \"empty.png\""
    end

    test "validates frame path confinement", %{dir: dir} do
      outside_path = Path.join(@tmp_base, "outside.png")
      File.write!(outside_path, "OUTSIDE")

      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => [%{"path" => "../outside.png", "holdMs" => 1000}]
          }
        ]
      })

      assert {:error, escape_err} = DemoValidator.validate(dir)
      assert escape_err =~ "is outside demo directory"
      File.rm(outside_path)
    end

    test "recorded demo must have at least one recorded segment", %{dir: dir} do
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Worker job",
            "outcome" => "not_filmable",
            "note" => "Headless"
          }
        ]
      })

      assert {:error, at_least_one} = DemoValidator.validate(dir)
      assert at_least_one =~ "A recorded demo must have at least one recorded segment"
    end

    test "valid recorded demo manifest succeeds", %{dir: dir} do
      ArtifactHelpers.write_demo_manifest(dir)
      criteria = ["User can view task"]

      assert {:ok, result} = DemoValidator.validate(dir, criteria: criteria)
      assert %{outcome: "recorded", version: 1, segments: [seg]} = result
      assert %{criterion_index: 1, outcome: :recorded, frames: [frame]} = seg
      assert %{path: "ac1-0.png", hold_ms: 1000, caption: "Viewing task screen"} = frame
    end

    test "validates segment and frame edge cases", %{dir: dir} do
      # Non-object segment
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => ["not_an_object"]
      })

      assert {:error, msg1} = DemoValidator.validate(dir)
      assert msg1 =~ "Segment at index 0 must be an object"

      # camelCase notFilmable outcome
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "notFilmable",
            "note" => "Skip UI"
          },
          %{
            "criterionIndex" => 2,
            "criterion" => "Test 2",
            "outcome" => "recorded",
            "frames" => [%{"path" => "ac1-0.png", "holdMs" => 500}]
          },
          %{
            "criterionIndex" => 3,
            "criterion" => "Test 3",
            "outcome" => "failed",
            "note" => "Failed to load page"
          }
        ]
      })

      assert {:ok, %{segments: [_s1, _s2, _s3]}} = DemoValidator.validate(dir)

      # Recorded segment with empty frames
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => []
          }
        ]
      })

      assert {:error, msg3} = DemoValidator.validate(dir)
      assert msg3 =~ "marked recorded but has no frames"

      # Recorded segment with >40 frames
      too_many_frames =
        for i <- 1..41 do
          %{"path" => "ac1-0.png", "holdMs" => 500, "caption" => "f_#{i}"}
        end

      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => too_many_frames
          }
        ]
      })

      assert {:error, msg4} = DemoValidator.validate(dir)
      assert msg4 =~ "exceeds the maximum limit of 40 frames"

      # Non-object frame
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => ["not_an_object"]
          }
        ]
      })

      assert {:error, msg5} = DemoValidator.validate(dir)
      assert msg5 =~ "frame 1 must be an object"

      # Frame missing path
      ArtifactHelpers.write_demo_manifest(dir, %{
        "segments" => [
          %{
            "criterionIndex" => 1,
            "criterion" => "Test",
            "outcome" => "recorded",
            "frames" => [%{"holdMs" => 500, "path" => ""}]
          }
        ]
      })

      assert {:error, msg6} = DemoValidator.validate(dir)
      assert msg6 =~ "is missing a path"
    end
  end

  describe "normalize_text/1" do
    test "normalizes markdown and whitespace" do
      assert DemoValidator.normalize_text("1. *Login* with `#GitHub`  auth_flow! ") ==
               "1. login with github authflow!"

      assert DemoValidator.normalize_text(nil) == ""
    end
  end
end
