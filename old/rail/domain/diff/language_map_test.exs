defmodule Rail.Domain.Diff.LanguageMapTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.LanguageMap

  test "supported_languages/0 returns exactly 22 languages" do
    languages = LanguageMap.supported_languages()
    assert length(languages) == 22
    assert "elixir" in languages
    assert "dart" in languages
    assert "yaml" in languages
    assert "ini" in languages

    atom_languages = LanguageMap.supported_languages(as: :atom)
    assert length(atom_languages) == 22
    assert :elixir in atom_languages
    assert :dart in atom_languages
  end

  test "extension_map/0 returns map with valid language values" do
    map = LanguageMap.extension_map()
    assert Map.get(map, ".ex") == "elixir"
    assert Map.get(map, ".dart") == "dart"
    assert Map.get(map, ".py") == "python"

    atom_map = LanguageMap.extension_map(as: :atom)
    assert Map.get(atom_map, ".ex") == :elixir
    assert Map.get(atom_map, ".dart") == :dart
  end

  test "maps general-purpose and systems languages from extensions" do
    assert LanguageMap.language_for_path("main.dart") == "dart"
    assert LanguageMap.language_for_path("router.ex") == "elixir"
    assert LanguageMap.language_for_path("mix.exs") == "elixir"
    assert LanguageMap.language_for_path("app.js") == "javascript"
    assert LanguageMap.language_for_path("bundle.mjs") == "javascript"
    assert LanguageMap.language_for_path("common.cjs") == "javascript"
    assert LanguageMap.language_for_path("types.ts") == "typescript"
    assert LanguageMap.language_for_path("module.mts") == "typescript"
    assert LanguageMap.language_for_path("script.cts") == "typescript"
    assert LanguageMap.language_for_path("server.py") == "python"
    assert LanguageMap.language_for_path("Activity.kt") == "kotlin"
    assert LanguageMap.language_for_path("build.kts") == "kotlin"
    assert LanguageMap.language_for_path("View.swift") == "swift"
    assert LanguageMap.language_for_path("legacy.m") == "objectivec"
    assert LanguageMap.language_for_path("header.h") == "objectivec"
    assert LanguageMap.language_for_path("Main.java") == "java"
    assert LanguageMap.language_for_path("server.go") == "go"
    assert LanguageMap.language_for_path("lib.rs") == "rust"
    assert LanguageMap.language_for_path("main.c") == "c"
    assert LanguageMap.language_for_path("engine.cpp") == "cpp"
    assert LanguageMap.language_for_path("core.cc") == "cpp"
    assert LanguageMap.language_for_path("module.cxx") == "cpp"
    assert LanguageMap.language_for_path("header.hpp") == "cpp"
    assert LanguageMap.language_for_path("base.hh") == "cpp"
    assert LanguageMap.language_for_path("script.rb") == "ruby"
  end

  test "maps scripting, markup, query and config languages from extensions" do
    assert LanguageMap.language_for_path("config.yaml") == "yaml"
    assert LanguageMap.language_for_path("deploy.yml") == "yaml"
    assert LanguageMap.language_for_path("data.json") == "json"
    assert LanguageMap.language_for_path("README.md") == "markdown"
    assert LanguageMap.language_for_path("notes.markdown") == "markdown"
    assert LanguageMap.language_for_path("run.sh") == "bash"
    assert LanguageMap.language_for_path("script.bash") == "bash"
    assert LanguageMap.language_for_path("env.zsh") == "bash"
    assert LanguageMap.language_for_path("layout.xml") == "xml"
    assert LanguageMap.language_for_path("index.html") == "xml"
    assert LanguageMap.language_for_path("page.htm") == "xml"
    assert LanguageMap.language_for_path("styles.css") == "css"
    assert LanguageMap.language_for_path("queries.sql") == "sql"
    assert LanguageMap.language_for_path("settings.ini") == "ini"
    assert LanguageMap.language_for_path("app.cfg") == "ini"
    assert LanguageMap.language_for_path("nginx.conf") == "ini"
    assert LanguageMap.language_for_path("build.properties") == "ini"
  end

  test "handles case insensitivity" do
    assert LanguageMap.language_for_path("MAIN.DART") == "dart"
    assert LanguageMap.language_for_path("App.EX") == "elixir"
    assert LanguageMap.language_for_path("Config.YML") == "yaml"
    assert LanguageMap.language_for_path("SCRIPT.SH") == "bash"
  end

  test "handles extension without leading dot" do
    assert LanguageMap.language_for_extension("ex") == "elixir"
    assert LanguageMap.language_for_extension(".ex") == "elixir"
    assert LanguageMap.language_for_extension("DART") == "dart"
  end

  test "handles files with multiple dots" do
    assert LanguageMap.language_for_path("component.spec.ts") == "typescript"
    assert LanguageMap.language_for_path("archive.tar.gz") == nil
  end

  test "returns nil for unrecognized extensions and files without extension" do
    assert LanguageMap.language_for_path("Dockerfile") == nil
    assert LanguageMap.language_for_path("LICENSE") == nil
    assert LanguageMap.language_for_path("notes.txt") == nil
    assert LanguageMap.language_for_path("document.pdf") == nil
    assert LanguageMap.language_for_path("") == nil
    assert LanguageMap.language_for_path(nil) == nil
    assert LanguageMap.language_for_extension(nil) == nil
    assert LanguageMap.language_for_extension("unknown") == nil
  end

  test "supports as: :atom option" do
    assert LanguageMap.language_for_path("lib.rs", as: :atom) == :rust
    assert LanguageMap.language_for_path("unknown.xyz", as: :atom) == nil
    assert LanguageMap.language_for_extension(".ex", as: :atom) == :elixir
    assert LanguageMap.language_for_extension("unknown", as: :atom) == nil
  end
end
