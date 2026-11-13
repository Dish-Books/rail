defmodule RailWeb.Utils.TestFileTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.TestFile

  test "a file named the way a test runner finds tests is a test" do
    for path <- [
          "lib/rail/filter_test.exs",
          "assets/js/filter.test.ts",
          "src/filter.spec.tsx",
          "app/filter-spec.js",
          "pkg/filter_test.go",
          "models/filter_spec.rb",
          "filter/test_filter.py",
          "filter/filter_tests.py",
          "src/main/FilterTest.java",
          "Filter/FilterTests.cs",
          "core/FilterSpec.scala"
        ] do
      assert test_file?(path), path
    end
  end

  test "a file under a test directory is a test, whatever it is called" do
    for path <- [
          "test/support/conn_case.ex",
          "tests/conftest.py",
          "src/__tests__/filter.js",
          "spec/spec_helper.rb",
          "src/__snapshots__/filter.js.snap"
        ] do
      assert test_file?(path), path
    end
  end

  test "a file that only has test somewhere in its name is not a test" do
    for path <- [
          "lib/rail/filter.ex",
          "lib/rail/latest.ex",
          "lib/rail/contest.ex",
          "lib/testing/filter.ex",
          "docs/tests.md",
          "lib/rail/testimonial_test_data.ex",
          "src/Latest.java",
          "mix.exs"
        ] do
      refute test_file?(path), path
    end
  end
end
