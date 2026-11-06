defmodule Rail.Pipeline.Utils.MatchesGlobTest do
  use ExUnit.Case, async: true

  import Rail.Pipeline.Utils.MatchesGlob

  test "a star stays in its directory and a double star crosses any number, none included" do
    assert matches_glob?("lib/rail/git_test.exs", "**/*_test.exs")
    assert matches_glob?("git_test.exs", "**/*_test.exs")
    refute matches_glob?("lib/rail/git.ex", "**/*_test.exs")

    assert matches_glob?("test/support/helpers.ex", "**/test/**")
    assert matches_glob?("apps/web/test/fixtures/a.json", "**/test/**")
    refute matches_glob?("lib/latest/a.ex", "**/test/**")

    assert matches_glob?("README.md", "*.md")
    refute matches_glob?("docs/README.md", "*.md")
    assert matches_glob?("docs/README.md", "**/*.md")
  end

  test "braces are either choice, and a question mark is one character" do
    for path <- ["web/a.test.ts", "web/a.test.tsx", "a.test.js"], do: assert(matches_glob?(path, "**/*.test.{ts,tsx,js}"))
    refute matches_glob?("web/a.test.jsx", "**/*.test.{ts,tsx,js}")
    refute matches_glob?("web/a.ts", "**/*.test.{ts,tsx,js}")

    assert matches_glob?("v1.ex", "v?.ex")
    refute matches_glob?("v10.ex", "v?.ex")
  end

  # A path is matched as text, so a dot or a plus in the glob is only itself.
  test "everything else in a glob is only itself" do
    refute matches_glob?("lib/axmd", "lib/a.md")
    assert matches_glob?("c++/a.md", "c++/*.md")
    assert matches_glob?("a{b.md", "a{b.md")
  end
end
