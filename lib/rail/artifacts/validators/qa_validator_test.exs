defmodule Rail.Artifacts.Validators.QaValidatorTest do
  use ExUnit.Case, async: true

  alias Rail.Artifacts.Validators.QaValidator
  alias RailTest.Support.ArtifactHelpers

  @tmp_base "tmp/test_qa_validator"

  setup do
    dir = Path.join(@tmp_base, "qa_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  describe "validate/2" do
    test "returns error when manifest does not exist", %{dir: dir} do
      assert {:error, msg} = QaValidator.validate(dir)
      assert msg =~ "QA manifest not found"
    end

    test "returns error when manifest is invalid JSON or not an object", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), "{invalid")
      assert {:error, msg} = QaValidator.validate(dir)
      assert msg =~ "Failed to parse QA manifest"

      File.write!(Path.join(dir, "manifest.json"), ~s(["not", "object"]))
      assert {:error, msg2} = QaValidator.validate(dir)
      assert msg2 =~ "QA manifest must be a JSON object"
    end

    test "validates session map and rows list existence", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"session" => "not_a_map"}))
      assert {:error, msg} = QaValidator.validate(dir)
      assert msg =~ "QA manifest missing valid \"session\" map"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"session" => %{}, "rows" => "not_a_list"})
      )

      assert {:error, msg2} = QaValidator.validate(dir)
      assert msg2 =~ "QA manifest missing \"rows\" list"
    end

    test "validates row fields, result, and severity", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"session" => %{}, "rows" => ["not_map"]})
      )

      assert {:error, msg} = QaValidator.validate(dir)
      assert msg =~ "QA row at index 0 must be an object"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{"session" => %{}, "rows" => [%{"id" => "c1"}]})
      )

      assert {:error, msg2} = QaValidator.validate(dir)
      assert msg2 =~ "QA row at index 0 missing required fields (id, check)"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [%{"id" => "c1", "check" => "Check 1", "result" => "unknown"}]
        })
      )

      assert {:error, msg3} = QaValidator.validate(dir)
      assert msg3 =~ "QA row at index 0 has invalid result: \"unknown\""

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [%{"id" => "c1", "check" => "Check 1", "result" => "pass", "severity" => "bad"}]
        })
      )

      assert {:error, msg4} = QaValidator.validate(dir)
      assert msg4 =~ "QA row at index 0 has invalid severity: \"bad\""
    end

    test "validates artifacts structure, kind, and path confinement", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [
            %{
              "id" => "c1",
              "check" => "Check 1",
              "result" => "pass",
              "severity" => "blocker",
              "artifacts" => "not_list"
            }
          ]
        })
      )

      assert {:error, msg} = QaValidator.validate(dir)
      assert msg =~ "artifacts must be a list"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [
            %{
              "id" => "c1",
              "check" => "Check 1",
              "result" => "pass",
              "severity" => "blocker",
              "artifacts" => [%{"name" => "test.txt", "kind" => "unknown"}]
            }
          ]
        })
      )

      assert {:error, msg2} = QaValidator.validate(dir)
      assert msg2 =~ "has invalid kind: \"unknown\""

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [
            %{
              "id" => "c1",
              "check" => "Check 1",
              "result" => "pass",
              "severity" => "blocker",
              "artifacts" => [%{"name" => "test.txt", "kind" => "text", "path" => "../escaped.txt"}]
            }
          ]
        })
      )

      assert {:error, msg3} = QaValidator.validate(dir)
      assert msg3 =~ "QA artifact path escapes qa directory"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [
            %{
              "id" => "c1",
              "check" => "Check 1",
              "result" => "pass",
              "severity" => "blocker",
              "artifacts" => ["not_object"]
            }
          ]
        })
      )

      assert {:error, msg4} = QaValidator.validate(dir)
      assert msg4 =~ "artifact 0 must be an object"

      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [
            %{
              "id" => "c1",
              "check" => "Check 1",
              "result" => "pass",
              "severity" => "blocker",
              "artifacts" => [%{"name" => "", "kind" => "text"}]
            }
          ]
        })
      )

      assert {:error, msg5} = QaValidator.validate(dir)
      assert msg5 =~ "artifact 0 is missing a name"
    end

    test "valid QA manifest succeeds", %{dir: dir} do
      ArtifactHelpers.write_qa_manifest(dir)

      assert {:ok, result} = QaValidator.validate(dir)
      assert %{commit: "abc1234", session: %{"port" => 4000}, rows: [row]} = result

      assert %{
               id: "check_1",
               check: "Login works",
               result: :pass,
               severity: :blocker,
               caused_by_change: true,
               command: "mix test",
               exit_code: 0,
               note: "Passed cleanly",
               artifacts: [art]
             } = row

      assert %{name: "screenshot.png", kind: :image} = art
    end

    test "handles text artifact without path and string exit codes", %{dir: dir} do
      File.write!(
        Path.join(dir, "manifest.json"),
        Jason.encode!(%{
          "session" => %{},
          "rows" => [
            %{
              "id" => "c_str",
              "check" => "Check string exit",
              "result" => "pass",
              "severity" => "nit",
              "exit_code" => "42",
              "artifacts" => [%{"name" => "log", "kind" => "text", "path" => nil, "text" => "done"}]
            },
            %{
              "id" => "c_bad",
              "check" => "Check bad exit",
              "result" => "skip",
              "severity" => "minor",
              "exit_code" => "invalid",
              "artifacts" => []
            },
            %{
              "id" => "c_crit",
              "check" => "Check crit",
              "result" => "fail",
              "severity" => "critical",
              "artifacts" => []
            },
            %{
              "id" => "c_maj",
              "check" => "Check maj",
              "result" => "fail",
              "severity" => "major",
              "artifacts" => []
            },
            %{
              "id" => "c_cosm",
              "check" => "Check cosm",
              "result" => "pass",
              "severity" => "cosmetic",
              "artifacts" => []
            }
          ]
        })
      )

      assert {:ok,
              %{
                rows: [
                  %{exit_code: 42, artifacts: [%{path: nil, resolved_path: nil}]},
                  %{exit_code: nil},
                  %{result: :fail, severity: :critical},
                  %{result: :fail, severity: :major},
                  %{severity: :cosmetic}
                ]
              }} = QaValidator.validate(dir)
    end
  end
end
