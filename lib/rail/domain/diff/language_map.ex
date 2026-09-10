defmodule Rail.Domain.Diff.LanguageMap do
  @moduledoc """
  Maps file paths and extensions to highlight.js language identifiers.

  Implements the 22 supported languages and extensions from spec 05 §8.7:
  dart, elixir, yaml, json, markdown, bash, javascript, typescript, python,
  xml, css, sql, kotlin, swift, objectivec, java, go, rust, c, cpp, ruby, ini.
  Unrecognized extensions return `nil`.
  """

  @extension_to_language %{
    ".dart" => "dart",
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".yaml" => "yaml",
    ".yml" => "yaml",
    ".json" => "json",
    ".md" => "markdown",
    ".markdown" => "markdown",
    ".sh" => "bash",
    ".bash" => "bash",
    ".zsh" => "bash",
    ".js" => "javascript",
    ".mjs" => "javascript",
    ".cjs" => "javascript",
    ".ts" => "typescript",
    ".mts" => "typescript",
    ".cts" => "typescript",
    ".py" => "python",
    ".xml" => "xml",
    ".html" => "xml",
    ".htm" => "xml",
    ".css" => "css",
    ".sql" => "sql",
    ".kt" => "kotlin",
    ".kts" => "kotlin",
    ".swift" => "swift",
    ".m" => "objectivec",
    ".h" => "objectivec",
    ".java" => "java",
    ".go" => "go",
    ".rs" => "rust",
    ".c" => "c",
    ".cpp" => "cpp",
    ".cc" => "cpp",
    ".cxx" => "cpp",
    ".hpp" => "cpp",
    ".hh" => "cpp",
    ".rb" => "ruby",
    ".ini" => "ini",
    ".cfg" => "ini",
    ".conf" => "ini",
    ".properties" => "ini"
  }

  @supported_languages [
    "bash",
    "c",
    "cpp",
    "css",
    "dart",
    "elixir",
    "go",
    "ini",
    "java",
    "javascript",
    "json",
    "kotlin",
    "markdown",
    "objectivec",
    "python",
    "ruby",
    "rust",
    "sql",
    "swift",
    "typescript",
    "xml",
    "yaml"
  ]

  @supported_language_atoms [
    :bash,
    :c,
    :cpp,
    :css,
    :dart,
    :elixir,
    :go,
    :ini,
    :java,
    :javascript,
    :json,
    :kotlin,
    :markdown,
    :objectivec,
    :python,
    :ruby,
    :rust,
    :sql,
    :swift,
    :typescript,
    :xml,
    :yaml
  ]

  @doc """
  Returns the language identifier for the given file path, or `nil` if unrecognized.
  Supports option `as: :atom` to return an atom identifier.
  """
  def language_for_path(path, opts \\ [])

  def language_for_path(nil, _opts), do: nil

  def language_for_path(path, opts) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()
    language_for_extension(ext, opts)
  end

  @doc """
  Returns the language identifier for the given file extension, or `nil` if unrecognized.
  Supports option `as: :atom` to return an atom identifier.
  """
  def language_for_extension(ext, opts \\ [])

  def language_for_extension(nil, _opts), do: nil

  def language_for_extension(ext, opts) when is_binary(ext) do
    normalized_ext =
      ext
      |> String.downcase()
      |> ensure_leading_dot()

    lang = Map.get(@extension_to_language, normalized_ext)

    format_result(lang, opts)
  end

  @doc """
  Returns the list of 22 supported language names.
  Supports option `as: :atom` to return a list of atoms.
  """
  def supported_languages(opts \\ []) do
    if Keyword.get(opts, :as) == :atom do
      @supported_language_atoms
    else
      @supported_languages
    end
  end

  @doc """
  Returns the full mapping of file extensions to language names.
  """
  def extension_map(opts \\ []) do
    if Keyword.get(opts, :as) == :atom do
      Map.new(@extension_to_language, fn {ext, lang} ->
        {ext, String.to_existing_atom(lang)}
      end)
    else
      @extension_to_language
    end
  end

  defp ensure_leading_dot("." <> _rest = ext), do: ext
  defp ensure_leading_dot(ext), do: "." <> ext

  defp format_result(lang, opts) do
    case {lang, Keyword.get(opts, :as)} do
      {nil, _opts} -> nil
      {str, :atom} -> String.to_existing_atom(str)
      {str, _opts} -> str
    end
  end
end
