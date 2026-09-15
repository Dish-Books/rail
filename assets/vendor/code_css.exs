# Writes assets/css/code.css from two Lumis themes.
#
#     mix run assets/vendor/code_css.exs
#
# `Rail.Git.Utils.HighlightLines` highlights with Lumis's `:html_linked`
# formatter, which names its tokens (`l-keyword`, `l-string`) and leaves the
# colors to a stylesheet. Lumis ships one stylesheet per theme, each a flat list
# of those class names; this reads two of them and writes one, the light theme's
# rules as they are and the dark theme's under `[data-theme="dark"]`, which is
# how the rest of the app spells dark mode.
#
# The themes' own `.lumis` rule is dropped: it paints a background, and the
# background of a diff line belongs to the diff.

light = "github_light"
dark = "onedark"

indent = fn body ->
  body |> String.split("\n", trim: true) |> Enum.map_join("\n", &"  #{String.trim(&1)}")
end

read = fn theme ->
  :lumis
  |> :code.priv_dir()
  |> Path.join("static/css/#{theme}.css")
  |> File.read!()
  |> then(&Regex.scan(~r/^(\.[\w-]+)\s*\{\n(.*?)^\}/ms, &1, capture: :all_but_first))
  |> Map.new(fn [selector, body] -> {selector, indent.(body)} end)
  |> Map.delete(".lumis")
end

light_rules = read.(light)
dark_rules = read.(dark)

rule = fn
  _selector, nil -> []
  selector, body -> ["#{selector} {\n#{body}\n}\n"]
end

body =
  [light_rules, dark_rules]
  |> Enum.flat_map(&Map.keys/1)
  |> Enum.uniq()
  |> Enum.sort()
  |> Enum.flat_map(fn selector ->
    rule.(selector, light_rules[selector]) ++ rule.(~s|[data-theme="dark"] #{selector}|, dark_rules[selector])
  end)

header = """
/* Syntax highlighting for the diff pane. Do not edit by hand.
 *
 * Generated from the Lumis themes #{light} (light) and #{dark} (dark) by
 * assets/vendor/code_css.exs, which is also where the why lives.
 */

"""

File.write!("assets/css/code.css", header <> Enum.join(body))
IO.puts("assets/css/code.css: #{map_size(light_rules)} light rules, #{map_size(dark_rules)} dark")
